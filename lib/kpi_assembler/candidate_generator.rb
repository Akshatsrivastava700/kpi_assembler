# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "schema_kpi_proposer"

module KPIAssembler
  # The inspector already decided which tables exist. This class only proposes
  # KPIs: the LLM (Gemini or Ollama) ranks those tables and writes recipes;
  # heuristics fill gaps. Certification never happens here.
  class CandidateGenerator
    MAX_CANDIDATES = 16
    MAX_PROMPT_TABLES = 24

    attr_reader :schema, :options, :meta

    def initialize(schema, options = {})
      @schema = schema
      @options = options
      @meta = default_meta
    end

    def generate
      heuristic = heuristic_candidates(schema.keys)
      return finalize(heuristic, proposer: "heuristics") unless use_llm?

      llm = prompt_llm
      unless llm
        return finalize(
          heuristic,
          proposer: "heuristics",
          fallback_reason: @meta[:fallback_reason]
        )
      end

      ranked = llm[:ranked_tables]
      merged = merge_candidates(llm[:kpis], heuristic)
      finalize(
        merged,
        proposer: "llm",
        ranked_tables: ranked,
        model: active_model_name
      )
    end

    private

    def default_meta
      {
        proposer: "heuristics",
        ranked_tables: [],
        model: nil,
        fallback_reason: nil
      }
    end

    def use_llm?
      return false if options[:use_llm] == false
      return false if llm_provider == :ollama && options[:use_ollama] == false

      true
    end

    def llm_provider
      provider = options[:llm_provider] || ENV["KPI_LLM_PROVIDER"]
      if provider && !provider.to_s.empty?
        provider.to_sym
      elsif options[:gemini_api_key] || ENV["GEMINI_API_KEY"]
        :gemini
      else
        :ollama
      end
    end

    def active_model_name
      llm_provider == :gemini ? gemini_model : ollama_model
    end

    def ollama_model
      options[:ollama_model] || ENV.fetch("KPI_OLLAMA_MODEL", "llama3")
    end

    def gemini_model
      options[:gemini_model] || ENV.fetch("KPI_GEMINI_MODEL", "gemini-2.0-flash")
    end

    def heuristic_candidates(table_names)
      names = Array(table_names).map(&:to_s)
      focused = schema.select { |name, _| names.include?(name.to_s) }
      focused = schema if focused.empty?
      SchemaKpiProposer.new(focused, options).propose
    end

    def prompt_llm
      case llm_provider
      when :gemini
        prompt_gemini
      else
        prompt_ollama
      end
    end

    def prompt_gemini
      api_key = options[:gemini_api_key] || ENV["GEMINI_API_KEY"]
      if api_key.nil? || api_key.to_s.empty?
        reason = "GEMINI_API_KEY is not set. Set GEMINI_API_KEY or configure KPI_LLM_PROVIDER=ollama."
        @meta = default_meta.merge(fallback_reason: reason)
        warn "Gemini proposal failed: #{reason}"
        return nil
      end

      model = gemini_model
      endpoint = options[:gemini_url] || "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent"
      known = schema.keys.map(&:to_s)
      prompt_text = build_prompt(known)

      uri = URI.parse(endpoint)
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "x-goog-api-key" => api_key)
      req.body = {
        contents: [
          {
            parts: [{ text: prompt_text }]
          }
        ],
        generationConfig: {
          responseMimeType: "application/json"
        }
      }.to_json

      res = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: Integer(options[:gemini_open_timeout] || 5),
        read_timeout: Integer(options[:gemini_timeout] || 60)
      ) { |http| http.request(req) }

      code = res.code.to_i
      unless code.between?(200, 299)
        @meta = default_meta.merge(fallback_reason: describe_gemini_error(code, res.body))
        return nil
      end

      raw_json = extract_gemini_text(res.body)
      parsed = extract_json(raw_json)
      ranked = sanitize_ranked_tables(parsed, known)
      kpis = sanitize_llm_kpis(parsed, known)
      if kpis.empty?
        @meta = default_meta.merge(fallback_reason: "Gemini returned no usable KPIs")
        return nil
      end

      { ranked_tables: ranked, kpis: kpis }
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, SocketError => e
      reason = "Cannot reach Gemini API (#{e.class}: #{e.message}). Check internet connection."
      @meta = default_meta.merge(fallback_reason: reason)
      warn "Gemini proposal failed: #{reason}"
      nil
    rescue Net::ReadTimeout
      seconds = Integer(options[:gemini_timeout] || 60)
      reason = "Gemini (#{model}) did not answer within #{seconds}s."
      @meta = default_meta.merge(fallback_reason: reason)
      warn "Gemini proposal failed: #{reason}"
      nil
    rescue StandardError => e
      @meta = default_meta.merge(fallback_reason: e.message)
      warn "Gemini proposal failed (#{e.message}). Using schema-driven heuristics."
      nil
    end

    def extract_gemini_text(body)
      parsed = JSON.parse(body)
      text = parsed.dig("candidates", 0, "content", "parts", 0, "text")
      text || body
    rescue StandardError
      body
    end

    def describe_gemini_error(code, body)
      detail = begin
        parsed = JSON.parse(body.to_s)
        parsed.dig("error", "message") || parsed["error"].to_s
      rescue StandardError
        ""
      end
      "Gemini API returned HTTP #{code}#{detail.empty? ? "" : ": #{detail}"}"
    end

    def prompt_ollama
      endpoint = options[:ollama_url] || "http://localhost:11434/api/generate"
      known = schema.keys.map(&:to_s)
      prompt_text = build_prompt(known)

      uri = URI.parse(endpoint)
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      req.body = {
        model: ollama_model,
        prompt: prompt_text,
        stream: false,
        format: "json"
      }.to_json

      res = Net::HTTP.start(
        uri.hostname,
        uri.port,
        open_timeout: Integer(options[:ollama_open_timeout] || 2),
        read_timeout: Integer(options[:ollama_timeout] || 900)
      ) { |http| http.request(req) }

      code = res.code.to_i
      unless code.between?(200, 299)
        @meta = default_meta.merge(fallback_reason: describe_http_error(code, res.body, endpoint))
        return nil
      end

      parsed = extract_json(res.body)
      ranked = sanitize_ranked_tables(parsed, known)
      kpis = sanitize_llm_kpis(parsed, known)
      if kpis.empty?
        @meta = default_meta.merge(fallback_reason: "Ollama returned no usable KPIs")
        return nil
      end

      { ranked_tables: ranked, kpis: kpis }
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, SocketError => e
      reason = "Cannot reach Ollama at #{endpoint} (#{e.class}). Start it with `ollama serve`."
      @meta = default_meta.merge(fallback_reason: reason)
      warn "Ollama proposal failed: #{reason}"
      nil
    rescue Net::ReadTimeout
      seconds = Integer(options[:ollama_timeout] || 90)
      reason = "#{ollama_model} did not answer within #{seconds}s. Use a smaller model or raise ollama_timeout."
      @meta = default_meta.merge(fallback_reason: reason)
      warn "Ollama proposal failed: #{reason}"
      nil
    rescue StandardError => e
      @meta = default_meta.merge(fallback_reason: e.message)
      warn "Ollama proposal failed (#{e.message}). Using schema-driven heuristics."
      nil
    end

    def build_prompt(known)
      dialect = options[:dialect] || "SQL"

      <<~PROMPT
        You are a business analytics architect. The tables below were already
        discovered by a schema inspector — do not invent tables or columns.

        1. Rank the most useful fact tables for KPIs (6 or fewer).
        2. Propose 6 to 10 KPI recipes for those tables.

        Reply ONLY with JSON:
        {
          "ranked_tables": ["table_name"],
          "kpis": [
            {
              "id": "snake_case_id",
              "name": "Human name",
              "category": "Sales Funnel|Revenue|Retention|Operations|Conversion",
              "owner": "sales|exec|ops|site_manager|finance",
              "formula_description": "One sentence in English",
              "sql": "SELECT ... AS metric_value FROM ... WHERE ...",
              "grain": "daily|weekly|monthly",
              "location_column": "location_id or company_id or null",
              "fact_table": "one of the provided table names"
            }
          ]
        }

        SQL rules:
        - Dialect: #{dialect}
        - Return a single column aliased metric_value.
        - Use two positional placeholders ? ? for period start and end.
        - Guard every division with NULLIF.
        - Only JOIN on real foreign keys. Never JOIN without ON.
        - fact_table and every FROM/JOIN target MUST be a provided table name.
        - Infer the domain from names. Do not assume a gym unless the schema looks like one.
        #{tenant_prompt_line}

        Discovered schema:
        #{JSON.pretty_generate(schema_for_prompt)}
      PROMPT
    end

    # Ollama reports a missing model as a 404 with a JSON error body. Say which
    # models the daemon actually has, so the fix does not need a support round trip.
    def describe_http_error(code, body, endpoint)
      detail = begin
        JSON.parse(body.to_s)["error"].to_s
      rescue StandardError
        ""
      end

      return "Ollama at #{endpoint} returned HTTP #{code}#{detail.empty? ? "" : ": #{detail}"}" unless code == 404

      installed = installed_models(endpoint)
      hint =
        if installed.empty?
          "No models are installed. Run `ollama pull #{ollama_model}`."
        else
          "Installed models: #{installed.join(", ")}. Run `ollama pull #{ollama_model}` or set ollama_model to one of these."
        end
      "Model #{ollama_model.inspect} is not available. #{hint}"
    end

    def installed_models(endpoint)
      uri = URI.parse(endpoint)
      tags = URI::HTTP.build(host: uri.host, port: uri.port, path: "/api/tags")
      body = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 5) do |http|
        http.request(Net::HTTP::Get.new(tags)).body
      end
      Array(JSON.parse(body)["models"]).map { |model| model["name"].to_s }.reject(&:empty?)
    rescue StandardError
      []
    end

    def extract_json(body)
      envelope = JSON.parse(body.to_s)
      payload = envelope.is_a?(Hash) ? envelope["response"] || envelope : envelope
      parsed =
        if payload.is_a?(String)
          JSON.parse(payload)
        else
          payload
        end
      parsed = parsed["kpis"] || parsed["candidates"] || parsed if parsed.is_a?(Hash) && !parsed.key?("kpis") && !parsed.key?("ranked_tables")
      parsed
    end

    def sanitize_ranked_tables(parsed, known)
      names =
        case parsed
        when Hash then Array(parsed["ranked_tables"] || parsed[:ranked_tables])
        else []
        end
      names.map(&:to_s).uniq.select { |name| known.include?(name) }
    end

    def sanitize_llm_kpis(parsed, known)
      rows =
        case parsed
        when Hash then Array(parsed["kpis"] || parsed[:kpis] || parsed["candidates"])
        when Array then parsed
        else []
        end

      rows.filter_map do |row|
        next unless row.respond_to?(:to_h)

        kpi = row.to_h.transform_keys(&:to_sym)
        fact = kpi[:fact_table].to_s
        fact = infer_fact_table(kpi[:sql], known) if fact.empty? || !known.include?(fact)
        next unless known.include?(fact)
        next if kpi[:sql].to_s.strip.empty? || kpi[:id].to_s.strip.empty?

        kpi.merge(fact_table: fact, source: "llm")
      end
    end

    def infer_fact_table(sql, known)
      match = sql.to_s.match(/\bfrom\s+["']?([a-zA-Z0-9_]+)["']?/i)
      name = match && match[1]
      known.include?(name) ? name : nil
    end

    def merge_candidates(llm_kpis, heuristic)
      seen = {}
      combined = []
      (Array(llm_kpis) + Array(heuristic)).each do |kpi|
        id = kpi[:id].to_s
        next if id.empty? || seen[id]

        seen[id] = true
        combined << kpi
      end
      combined.first(MAX_CANDIDATES)
    end

    def finalize(candidates, proposer:, ranked_tables: [], model: nil, fallback_reason: nil)
      normalized = normalize(candidates)
      @meta = {
        proposer: proposer,
        ranked_tables: Array(ranked_tables),
        model: model,
        fallback_reason: fallback_reason
      }
      normalized
    end

    def tenant_prompt_line
      column = options[:tenant_column]
      return "" unless column

      "If a table has #{column}, every query on that table MUST include #{column} = #{options[:tenant_id] || "?"}."
    end

    def schema_for_prompt
      schema.first(MAX_PROMPT_TABLES).to_h.transform_values do |meta|
        {
          row_count: meta[:row_count],
          columns: Array(meta[:columns]).map { |col| { name: col[:name], type: col[:type] } },
          time_columns: meta[:time_columns],
          foreign_keys: Array(meta[:foreign_keys]).map { |fk| fk.slice(:table, :from, :to) },
          categorical_values: meta[:categorical_values]
        }
      end
    end

    def normalize(candidates)
      candidates.map do |kpi|
        h = kpi.transform_keys(&:to_sym)
        h[:sql] = h[:sql].to_s.strip.sub(/;\s*\z/, "")
        h[:grain] = h[:grain].to_s
        h[:source] ||= "heuristics"
        h[:location_column] = nil if h[:location_column].to_s.match?(/\A(null|nil|none)?\z/i)
        h
      end
    end
  end
end
