# frozen_string_literal: true

require "time"

module KPIAssembler
  class PackBuilder
    def initialize(certified_kpis, drafts: [], briefing: {}, evaluations: {}, schema: {}, version: KPIAssembler::VERSION)
      @certified_kpis = certified_kpis
      @drafts = drafts
      @briefing = briefing
      @evaluations = evaluations
      @schema = schema
      @version = version
    end

    def build
      {
        pack_name: "Certified KPI Pack",
        version: "1.0.0",
        generated_at: Time.now.utc.iso8601,
        certified_by: "KPIAssembler v#{@version}",
        principle: "The LLM proposes; deterministic code certifies.",
        catalog: catalog_entries,
        kpis: @certified_kpis,
        drafts: @drafts,
        evaluations: @evaluations,
        briefing: @briefing,
        lineage: {
          tables: @schema.keys,
          grain: "lead → appointment → membership → invoice",
          dimension: "location"
        }
      }
    end

    private

    def catalog_entries
      (@certified_kpis + @drafts).map do |kpi|
        {
          id: kpi[:id],
          name: kpi[:name],
          english: kpi[:formula_description],
          sql: kpi[:sql],
          grain: kpi[:grain],
          owner: kpi[:owner],
          status: kpi[:status],
          reasons: kpi[:reasons]
        }
      end
    end
  end
end
