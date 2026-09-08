# frozen_string_literal: true

require "spec_helper"

RSpec.describe KPIAssembler::CertificationEngine do
  let(:db) { KPIAssembler::SampleDatabase.build }
  let(:schema) { KPIAssembler::SchemaInspector.new(db).introspect }
  let(:engine) { described_class.new(db, schema) }

  it "certifies a guarded conversion-rate query" do
    kpi = {
      id: "lead_conversion_rate",
      name: "Lead to Member Conversion Rate",
      sql: "SELECT (CAST(COUNT(CASE WHEN status = 'converted' THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0)) * 100 AS metric_value FROM leads WHERE created_at >= ? AND created_at < ?",
      grain: "daily",
      location_column: "location_id"
    }
    certified, drafts = engine.certify([kpi])
    expect(drafts).to be_empty
    expect(certified.first[:status]).to eq("certified")
  end

  it "keeps an unconstrained join in draft instead of publishing it" do
    kpi = {
      id: "revenue_per_lead_unsafe",
      name: "Revenue per Lead",
      sql: "SELECT SUM(invoices.amount) / COUNT(leads.id) AS metric_value FROM leads JOIN invoices WHERE leads.created_at >= ? AND leads.created_at < ?",
      grain: "monthly"
    }
    certified, drafts = engine.certify([kpi])
    expect(certified).to be_empty
    expect(drafts.first[:status]).to eq("draft")
    expect(drafts.first[:reasons].join).to match(/JOIN without ON|Unsafe division/)
  end

  it "rejects SQL that references missing tables" do
    kpi = {
      id: "ghost",
      name: "Ghost",
      sql: "SELECT COUNT(*) AS metric_value FROM not_a_table",
      grain: "daily"
    }
    _, drafts = engine.certify([kpi])
    expect(drafts.first[:reasons].join).to match(/unknown tables/)
  end
end
