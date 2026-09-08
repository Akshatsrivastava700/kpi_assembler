# frozen_string_literal: true

require "spec_helper"

RSpec.describe KPIAssembler::CandidateGenerator do
  def schema
    KPIAssembler::SchemaInspector.new(KPIAssembler::SampleDatabase.build).introspect
  end

  def stub_ollama(payload)
    response = instance_double(Net::HTTPResponse, code: "200", body: { "response" => JSON.generate(payload) }.to_json)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  def stub_gemini(payload, code: "200")
    body =
      if code == "200"
        {
          candidates: [
            {
              content: {
                parts: [
                  { text: JSON.generate(payload) }
                ]
              }
            }
          ]
        }.to_json
      else
        { error: { message: "Quota exceeded" } }.to_json
      end

    response = instance_double(Net::HTTPResponse, code: code, body: body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  it "uses heuristics when the LLM is disabled" do
    generator = described_class.new(schema, use_llm: false, llm_provider: :ollama)
    ids = generator.generate.map { |kpi| kpi[:id] }

    expect(ids).to include("lead_conversion_rate")
    expect(generator.meta[:proposer]).to eq("heuristics")
    expect(generator.generate.first[:source]).to eq("heuristics")
  end

  describe "Ollama provider" do
    it "ranks inspector tables and merges Ollama KPIs with heuristics" do
      stub_ollama(
        {
          ranked_tables: %w[leads invoices sqlite_invented],
          kpis: [
            {
              id: "llm_lead_volume",
              name: "Lead volume",
              category: "Sales Funnel",
              owner: "sales",
              formula_description: "Leads created in the period.",
              sql: "SELECT COUNT(*) AS metric_value FROM leads WHERE created_at >= ? AND created_at < ?",
              grain: "daily",
              location_column: "location_id",
              fact_table: "leads"
            },
            {
              id: "invented_table_kpi",
              name: "Should be dropped",
              sql: "SELECT 1 AS metric_value FROM ghosts",
              fact_table: "ghosts"
            }
          ]
        }
      )

      generator = described_class.new(schema, use_llm: true, llm_provider: :ollama, dialect: "SQLite")
      candidates = generator.generate
      ids = candidates.map { |kpi| kpi[:id] }

      expect(generator.meta[:proposer]).to eq("llm")
      expect(generator.meta[:model]).to eq("llama3")
      expect(generator.meta[:ranked_tables]).to eq(%w[leads invoices])
      expect(ids).to include("llm_lead_volume")
      expect(ids).not_to include("invented_table_kpi")
      expect(ids).to include("paid_mrr")
      expect(candidates.find { |kpi| kpi[:id] == "llm_lead_volume" }[:source]).to eq("llm")
    end

    it "falls back to heuristics when Ollama is unreachable" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      generator = described_class.new(schema, use_llm: true, llm_provider: :ollama)
      ids = generator.generate.map { |kpi| kpi[:id] }

      expect(ids).to include("lead_conversion_rate")
      expect(generator.meta[:proposer]).to eq("heuristics")
      expect(generator.meta[:fallback_reason]).to match(/refused/i)
    end
  end

  describe "Gemini provider" do
    it "ranks inspector tables and generates KPIs via Gemini API" do
      stub_gemini(
        {
          ranked_tables: %w[memberships leads],
          kpis: [
            {
              id: "gemini_active_members",
              name: "Active Members",
              category: "Retention",
              owner: "ops",
              formula_description: "Active memberships during period.",
              sql: "SELECT COUNT(*) AS metric_value FROM memberships WHERE starts_on <= ? AND ends_on >= ?",
              grain: "monthly",
              fact_table: "memberships"
            }
          ]
        }
      )

      generator = described_class.new(
        schema,
        use_llm: true,
        llm_provider: :gemini,
        gemini_api_key: "test-fake-key",
        gemini_model: "gemini-2.0-flash"
      )
      candidates = generator.generate
      ids = candidates.map { |kpi| kpi[:id] }

      expect(generator.meta[:proposer]).to eq("llm")
      expect(generator.meta[:model]).to eq("gemini-2.0-flash")
      expect(generator.meta[:ranked_tables]).to eq(%w[memberships leads])
      expect(ids).to include("gemini_active_members")
      expect(ids).to include("lead_conversion_rate")
      expect(candidates.find { |kpi| kpi[:id] == "gemini_active_members" }[:source]).to eq("llm")
    end

    it "still uses Gemini when the Ollama flag is off" do
      stub_gemini(
        {
          ranked_tables: %w[leads],
          kpis: [
            {
              id: "gemini_lead_count",
              name: "Lead count",
              sql: "SELECT COUNT(*) AS metric_value FROM leads WHERE created_at >= ? AND created_at < ?",
              fact_table: "leads"
            }
          ]
        }
      )

      generator = described_class.new(
        schema,
        use_ollama: false,
        llm_provider: :gemini,
        gemini_api_key: "test-fake-key"
      )

      expect(generator.generate.map { |kpi| kpi[:id] }).to include("gemini_lead_count")
      expect(generator.meta[:proposer]).to eq("llm")
    end

    it "falls back to heuristics when GEMINI_API_KEY is missing" do
      generator = described_class.new(
        schema,
        use_llm: true,
        llm_provider: :gemini,
        gemini_api_key: nil
      )
      ids = generator.generate.map { |kpi| kpi[:id] }

      expect(ids).to include("lead_conversion_rate")
      expect(generator.meta[:proposer]).to eq("heuristics")
      expect(generator.meta[:fallback_reason]).to match(/GEMINI_API_KEY/i)
    end

    it "falls back to heuristics on Gemini API HTTP errors" do
      stub_gemini({}, code: "429")

      generator = described_class.new(
        schema,
        use_llm: true,
        llm_provider: :gemini,
        gemini_api_key: "test-fake-key"
      )
      ids = generator.generate.map { |kpi| kpi[:id] }

      expect(ids).to include("lead_conversion_rate")
      expect(generator.meta[:proposer]).to eq("heuristics")
      expect(generator.meta[:fallback_reason]).to match(/HTTP 429.*Quota exceeded/i)
    end
  end
end
