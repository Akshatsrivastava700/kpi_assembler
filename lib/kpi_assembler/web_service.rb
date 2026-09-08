# frozen_string_literal: true

require "thread"
require_relative "connection"
require_relative "location_directory"

module KPIAssembler
  class WebService
    attr_reader :db, :options

    def initialize(db:, options: {})
      @db = Connection.wrap(db)
      @options = options
      @mutex = Mutex.new
      @schema = nil
      @candidates = nil
      @pack = nil
    end

    def discover
      @mutex.synchronize { run_discovery }
    end

    def certify(accepted_ids)
      @mutex.synchronize do
        ids = Array(accepted_ids).map(&:to_s).uniq
        raise Error, "Select at least one KPI to certify" if ids.empty?

        # Discovery state lives in process memory, so a certify request can reach a
        # worker that never served the matching discover request. Rebuild rather
        # than rejecting a selection the user legitimately made.
        run_discovery unless @schema && @candidates

        known_ids = @candidates.map { |candidate| candidate[:id].to_s }
        unknown_ids = ids - known_ids
        raise Error, "Unknown KPI IDs: #{unknown_ids.join(', ')}" unless unknown_ids.empty?

        selected = @candidates.select { |candidate| ids.include?(candidate[:id].to_s) }
        now = options[:now] || Time.now.utc
        certified, drafts = CertificationEngine.new(
          db,
          @schema,
          now: now,
          tenant_column: options[:tenant_column],
          tenant_id: options[:tenant_id]
        ).certify(selected)
        evaluations = evaluate_views(certified, now)
        briefing = BriefingGenerator.new(db, certified, now: now, tenant_id: options[:tenant_id]).generate

        @pack = PackBuilder.new(
          certified,
          drafts: drafts,
          briefing: briefing,
          evaluations: evaluations,
          schema: @schema
        ).build
      end
    end

    def pack
      @mutex.synchronize { @pack }
    end

    def locations
      LocationDirectory.new(db, tenant_id: options[:tenant_id]).all
    end

    private

    def run_discovery
      inspector = SchemaInspector.new(db, inspector_options)
      @schema = inspector.introspect
      generator = CandidateGenerator.new(@schema, generator_options)
      @candidates = generator.generate
      @pack = nil

      {
        source: options[:source_name] || db.label,
        dialect: db.dialect,
        schema_name: db.postgres? ? inspector_options[:schema_name] : nil,
        tables: schema_summary,
        missing_tables: inspector.missing_tables,
        omitted_tables: inspector.omitted_tables,
        max_tables: inspector_options[:max_tables],
        proposer: generator.meta[:proposer],
        proposer_model: generator.meta[:model],
        proposer_fallback: generator.meta[:fallback_reason],
        ranked_tables: generator.meta[:ranked_tables],
        candidates: @candidates
      }
    end

    def inspector_options
      {
        include_tables: Array(options[:include_tables]),
        max_tables: options[:max_tables],
        schema_name: options[:schema_name]
      }
    end

    def generator_options
      options.merge(dialect: db.dialect)
    end

    def schema_summary
      @schema.map do |name, metadata|
        {
          name: name,
          row_count: metadata[:row_count],
          columns: metadata[:columns].map { |column| column.slice(:name, :type, :pk) },
          foreign_keys: metadata[:foreign_keys],
          time_columns: metadata[:time_columns]
        }
      end
    end

    def evaluate_views(certified, now)
      evaluator = MetricEvaluator.new(db)
      from = now - (30 * 86_400)
      result = { "all" => values_for(evaluator, certified, from, now, nil) }
      locations.each do |location|
        result[location[:id].to_s] = values_for(evaluator, certified, from, now, location[:id])
      end
      result
    end

    def values_for(evaluator, certified, from, to, location_id)
      certified.each_with_object({}) do |kpi, result|
        result[kpi[:id]] = evaluator.value(
          kpi,
          from: from,
          to: to,
          location_id: location_id
        )
      end
    end
  end
end
