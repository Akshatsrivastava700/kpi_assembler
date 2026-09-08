# frozen_string_literal: true

require_relative "metric_evaluator"
require_relative "location_directory"

module KPIAssembler
  class BriefingGenerator
    def initialize(db, certified_kpis, now: Time.now.utc, tenant_id: nil)
      @evaluator = MetricEvaluator.new(db)
      @kpis = certified_kpis
      @now = now
      @tenant_id = tenant_id
      @current_from = now - (30 * 86_400)
      @previous_from = now - (60 * 86_400)
    end

    def generate
      movements = @kpis.filter_map { |kpi| movement_for(kpi) }
      ranked = movements.sort_by { |m| -m[:abs_delta_pct] }.first(3)
      drill = worst_location_for(ranked.first)

      {
        period: {
          current: { from: iso(@current_from), to: iso(@now) },
          previous: { from: iso(@previous_from), to: iso(@current_from) }
        },
        headline: headline(ranked),
        movements: ranked,
        drill_dimension: drill
      }
    end

    private

    def movement_for(kpi)
      current = @evaluator.value(kpi, from: @current_from, to: @now)
      previous = @evaluator.value(kpi, from: @previous_from, to: @current_from)
      return if current.nil? || previous.nil?

      delta = current - previous
      base = previous.abs < 0.0001 ? nil : ((delta / previous) * 100.0)
      {
        id: kpi[:id],
        name: kpi[:name],
        current: round_num(current),
        previous: round_num(previous),
        delta: round_num(delta),
        delta_pct: base && round_num(base),
        abs_delta_pct: (base || delta).abs,
        sentence: sentence(kpi[:name], current, previous, delta, base)
      }
    end

    def worst_location_for(movement)
      return { dimension: "location", note: "No certified movement to drill." } unless movement

      kpi = @kpis.find { |k| k[:id] == movement[:id] }
      return { dimension: "location", note: "KPI has no location column." } unless kpi && kpi[:location_column]

      rows = db_locations.filter_map do |loc|
        value = @evaluator.value(kpi, from: @current_from, to: @now, location_id: loc[:id])
        next unless value

        { id: loc[:id], name: loc[:name], value: round_num(value) }
      end
      worst = rows.min_by { |r| r[:value] }
      {
        dimension: "location",
        kpi_id: movement[:id],
        locations: rows,
        explaining_site: worst
      }
    end

    def db_locations
      LocationDirectory.new(@evaluator.db, tenant_id: @tenant_id).all
    rescue StandardError
      []
    end

    def headline(ranked)
      return "No certified KPIs moved enough to brief." if ranked.empty?

      ranked.map { |m| m[:sentence] }.join(" ")
    end

    def sentence(name, current, previous, delta, delta_pct)
      direction = delta.negative? ? "fell" : "rose"
      if delta_pct
        "#{name} #{direction} #{format('%.1f', delta_pct.abs)} pts/percent vs the prior 30 days (#{format_num(previous)} → #{format_num(current)})."
      else
        "#{name} is #{format_num(current)} this period vs #{format_num(previous)} prior."
      end
    end

    def format_num(n)
      n.abs >= 100 ? format("%.0f", n) : format("%.1f", n)
    end

    def round_num(n)
      n.round(2)
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
