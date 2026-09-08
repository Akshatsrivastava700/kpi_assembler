# frozen_string_literal: true

require_relative "connection"

module KPIAssembler
  class MetricEvaluator
    attr_reader :db

    def initialize(db)
      @db = Connection.wrap(db)
    end

    def value(kpi, from:, to:, location_id: nil)
      sql = scoped_sql(kpi, location_id: location_id)
      binds = period_binds(kpi, from: from, to: to)
      rows =
        if placeholder_count(sql).positive?
          db.execute(sql, binds)
        else
          db.execute(sql)
        end
      raw = rows.dig(0, 0)
      return nil if raw.nil?

      Float(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def scoped_sql(kpi, location_id: nil)
      sql = kpi[:sql].to_s.strip.sub(/;\s*\z/, "")
      return sql unless location_id && kpi[:location_column].to_s.strip != ""

      col = kpi[:location_column]
      clause = "#{col} = #{Integer(location_id)}"
      if sql.match?(/\bWHERE\b/i)
        sql.sub(/\bWHERE\b/i, "WHERE #{clause} AND ")
      else
        "#{sql} WHERE #{clause}"
      end
    end

    def period_binds(kpi, from:, to:)
      from_s = iso(from)
      to_s = iso(to)
      if kpi[:bind_style].to_s == "end_then_start"
        [to_s, from_s]
      else
        [from_s, to_s]
      end
    end

    def placeholder_count(sql)
      sql.scan("?").length
    end

    def iso(time)
      time = Time.parse(time.to_s) unless time.is_a?(Time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
