# frozen_string_literal: true

require "time"
require_relative "connection"
require_relative "metric_evaluator"

module KPIAssembler
  class CertificationEngine
    attr_reader :db, :schema, :evaluator

    def initialize(db, schema, now: Time.now.utc, tenant_column: nil, tenant_id: nil)
      @db = Connection.wrap(db)
      @schema = schema
      @now = now
      @tenant_column = tenant_column
      @tenant_id = tenant_id
      @evaluator = MetricEvaluator.new(@db)
    end

    def certify(candidates)
      certified = []
      drafts = []

      candidates.each do |kpi|
        reasons = collect_reasons(kpi)
        record = kpi.merge(certified_at: @now.iso8601)

        if reasons.empty?
          certified << record.merge(status: "certified")
        else
          drafts << record.merge(status: "draft", reasons: reasons)
        end
      end

      [certified, drafts]
    end

    private

    def collect_reasons(kpi)
      reasons = []
      sql = kpi[:sql].to_s

      reasons << "Only one read-only SELECT statement is allowed" unless read_only_select?(sql)
      reasons << "Missing aggregation grain" if kpi[:grain].to_s.strip.empty?
      reasons.concat(schema_reasons(sql))
      reasons.concat(tenant_scope_reasons(kpi, sql))
      reasons << "JOIN without ON — unconstrained join / cartesian risk" if join_without_on?(sql)
      reasons << "Unsafe division without NULLIF or CASE" if unsafe_division?(sql)
      reasons.concat(execution_reasons(kpi))
      reasons
    end

    def schema_reasons(sql)
      unknown = referenced_tables(sql) - schema.keys.map(&:to_s)
      return [] if unknown.empty?

      ["References unknown tables: #{unknown.join(", ")}"]
    end

    def referenced_tables(sql)
      sql.scan(/\b(?:FROM|JOIN)\s+([A-Za-z_][A-Za-z0-9_]*)/i).flatten.map(&:downcase).uniq
    end

    def read_only_select?(sql)
      statement = sql.strip
      return false unless statement.match?(/\A(?:SELECT|WITH)\b/i)
      return false if statement.sub(/;\s*\z/, "").include?(";")

      !statement.match?(/\b(?:INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|COPY)\b/i)
    end

    def tenant_scope_reasons(kpi, sql)
      return [] unless @tenant_column && @tenant_id

      fact_table = kpi[:fact_table].to_s
      columns = Array(schema.dig(fact_table, :columns)).map { |column| column[:name] }
      return [] unless columns.include?(@tenant_column.to_s)

      pattern = /\b#{Regexp.escape(@tenant_column.to_s)}\s*=\s*#{Regexp.escape(@tenant_id.to_s)}\b/i
      return [] if sql.match?(pattern)

      ["Missing required tenant scope: #{@tenant_column} = #{@tenant_id}"]
    end

    def join_without_on?(sql)
      sql.split(/\bJOIN\b/i).drop(1).any? { |fragment| !fragment.match?(/\bON\b/i) }
    end

    def unsafe_division?(sql)
      return false unless sql.include?("/")

      !sql.match?(/\bNULLIF\b/i) && !sql.match?(/\bCASE\b/i)
    end

    def execution_reasons(kpi)
      reasons = []
      from = @now - (30 * 86_400)
      to = @now

      begin
        plan_sql = evaluator.scoped_sql(kpi).gsub("?", "'2000-01-01T00:00:00Z'")
        db.explain(plan_sql)
      rescue StandardError => e
        reasons << "SQL syntax or planner error: #{e.message}"
        return reasons
      end

      begin
        value = evaluator.value(kpi, from: from, to: to)
      rescue StandardError => e
        reasons << "Execution failed on sample period: #{e.message}"
        return reasons
      end

      if value.nil?
        reasons << "Sample-period replay returned NULL"
      elsif !value.finite?
        reasons << "Sample-period replay returned non-finite value"
      end

      reasons
    end
  end
end
