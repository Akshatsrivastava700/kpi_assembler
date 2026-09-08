# frozen_string_literal: true

require "json"
require_relative "kpi_assembler/version"
require_relative "kpi_assembler/env"

KPIAssembler::Env.load_defaults!

module KPIAssembler
  class Error < StandardError; end

  autoload :SampleDatabase, File.expand_path("kpi_assembler/sample_database", __dir__)
end

require_relative "kpi_assembler/connection"
require_relative "kpi_assembler/schema_inspector"
require_relative "kpi_assembler/schema_kpi_proposer"
require_relative "kpi_assembler/candidate_generator"
require_relative "kpi_assembler/certification_engine"
require_relative "kpi_assembler/metric_evaluator"
require_relative "kpi_assembler/location_directory"
require_relative "kpi_assembler/briefing_generator"
require_relative "kpi_assembler/pack_builder"
require_relative "kpi_assembler/html_report"
require_relative "kpi_assembler/web_service"
require_relative "kpi_assembler/asset_server"
require_relative "kpi_assembler/configuration"

module KPIAssembler
  DEMO_ACCEPT = %w[
    lead_conversion_rate
    tour_show_rate
    paid_mrr
    avg_revenue_per_member
    revenue_per_lead_unsafe
  ].freeze

  class Pipeline
    attr_reader :db_connection, :options, :now

    def initialize(db_connection:, options: {})
      @db_connection = Connection.wrap(db_connection)
      @options = options
      @now = options[:now] || Time.now.utc
    end

    def run
      puts "==> [1/6] Discover — introspect schema and profile tables..."
      schema = SchemaInspector.new(db_connection, inspector_options).introspect
      schema.each do |name, meta|
        puts "    #{name}: #{meta[:row_count]} rows, FKs=#{meta[:foreign_keys].size}"
      end

      puts "==> [2/6] Propose — candidate KPI recipes from this schema..."
      generator = CandidateGenerator.new(schema, generator_options)
      candidates = generator.generate
      puts "    proposer: #{generator.meta[:proposer]}" +
           (generator.meta[:fallback_reason] ? " (#{generator.meta[:fallback_reason]})" : "")
      unless generator.meta[:ranked_tables].empty?
        puts "    ranked tables: #{generator.meta[:ranked_tables].join(", ")}"
      end
      candidates.each { |kpi| puts "    • #{kpi[:id]} — #{kpi[:name]} [#{kpi[:source]}]" }

      puts "==> [3/6] Accept — human gate on catalog entries..."
      accepted = apply_human_gate(candidates)
      puts "    Accepted #{accepted.size} of #{candidates.size} candidates."

      puts "==> [4/6] Certify — deterministic replay (LLM never certifies)..."
      certified, drafts = CertificationEngine.new(
        db_connection,
        schema,
        now: now,
        tenant_column: options[:tenant_column],
        tenant_id: options[:tenant_id]
      ).certify(accepted)
      puts "    Certified: #{certified.size} | Draft (failed): #{drafts.size}"
      drafts.each { |kpi| puts "    ✗ #{kpi[:id]}: #{Array(kpi[:reasons]).join("; ")}" }

      puts "==> [5/6] Evaluate role views (exec + site)..."
      evaluations = evaluate_views(certified)

      puts "==> [6/6] Publish pack + briefing..."
      briefing = BriefingGenerator.new(
        db_connection,
        certified,
        now: now,
        tenant_id: options[:tenant_id]
      ).generate
      puts "    #{briefing[:headline]}"

      PackBuilder.new(
        certified,
        drafts: drafts,
        briefing: briefing,
        evaluations: evaluations,
        schema: schema
      ).build
    end

    def write_outputs!(pack, directory)
      require "fileutils"
      FileUtils.mkdir_p(directory)
      json_path = File.join(directory, "kpi_pack.json")
      html_path = File.join(directory, "kpi_pack.html")
      File.write(json_path, JSON.pretty_generate(pack))
      html = HtmlReport.new(pack, locations: load_locations).render
      File.write(html_path, html)
      [json_path, html_path]
    end

    private

    def inspector_options
      {
        include_tables: Array(options[:include_tables]),
        max_tables: options[:max_tables],
        schema_name: options[:schema_name]
      }
    end

    def generator_options
      options.merge(dialect: db_connection.dialect)
    end

    def apply_human_gate(candidates)
      ids = Array(options[:accept_ids]).map(&:to_s)
      if ids.empty? && options[:demo] != false
        demo_ids = candidates.map { |kpi| kpi[:id].to_s } & DEMO_ACCEPT
        ids = demo_ids.empty? ? candidates.map { |kpi| kpi[:id].to_s } : demo_ids
      end
      return candidates if options[:accept_all] || ids.empty?

      selected = candidates.select { |kpi| ids.include?(kpi[:id].to_s) }
      missing = ids - selected.map { |kpi| kpi[:id].to_s }
      warn "    Unknown accept ids: #{missing.join(", ")}" unless missing.empty?
      selected
    end

    def evaluate_views(certified)
      evaluator = MetricEvaluator.new(db_connection)
      from = now - (30 * 86_400)
      to = now
      result = { "all" => values_for(evaluator, certified, from, to, nil) }
      load_locations.each do |loc|
        result[loc[:id].to_s] = values_for(evaluator, certified, from, to, loc[:id])
      end
      result
    end

    def values_for(evaluator, certified, from, to, location_id)
      certified.each_with_object({}) do |kpi, acc|
        acc[kpi[:id]] = evaluator.value(kpi, from: from, to: to, location_id: location_id)
      end
    end

    def load_locations
      LocationDirectory.new(db_connection, tenant_id: options[:tenant_id]).all
    end
  end
end

require_relative "kpi_assembler/engine" if defined?(Rails::Engine)
