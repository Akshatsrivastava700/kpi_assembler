# frozen_string_literal: true

require "spec_helper"

RSpec.describe KPIAssembler::SchemaKpiProposer do
  def schema_for(db)
    KPIAssembler::SchemaInspector.new(db).introspect
  end

  it "proposes sample funnel KPIs including the unsafe certification fixture" do
    db = KPIAssembler::SampleDatabase.build
    ids = described_class.new(schema_for(db)).propose.map { |kpi| kpi[:id] }
    expect(ids).to include("lead_conversion_rate", "paid_mrr", "revenue_per_lead_unsafe")
  end

  it "proposes KPIs from people and activities tables" do
    db = SQLite3::Database.new(":memory:")
    db.execute_batch(<<~SQL)
      CREATE TABLE people (
        id INTEGER PRIMARY KEY,
        company_id INTEGER,
        status TEXT,
        created_at TEXT,
        sale_at TEXT,
        deleted_at TEXT
      );
      CREATE TABLE activities (
        id INTEGER PRIMARY KEY,
        company_id INTEGER,
        type TEXT,
        start TEXT,
        complete INTEGER,
        sales_amount REAL,
        deleted_at TEXT
      );
      CREATE TABLE companies (id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO people (company_id, status, created_at, sale_at) VALUES (1, 'lead', '2026-08-01T00:00:00Z', NULL);
      INSERT INTO people (company_id, status, created_at, sale_at) VALUES (1, 'member', '2026-08-02T00:00:00Z', '2026-08-10T00:00:00Z');
      INSERT INTO activities (company_id, type, start, complete, sales_amount) VALUES (1, 'Event', '2026-08-03T00:00:00Z', 1, 99);
    SQL

    ids = described_class.new(schema_for(db)).propose.map { |kpi| kpi[:id] }
    expect(ids).to include("new_leads", "lead_close_rate", "scheduled_appointments")
  end

  it "proposes volume and money KPIs from an unknown app schema" do
    db = SQLite3::Database.new(":memory:")
    db.execute_batch(<<~SQL)
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY,
        amount REAL,
        status TEXT,
        created_at TEXT
      );
      INSERT INTO orders (amount, status, created_at) VALUES (20, 'paid', '2026-08-01T00:00:00Z');
    SQL

    candidates = described_class.new(schema_for(db)).propose
    expect(candidates.map { |kpi| kpi[:id] }).to include("orders_amount_sum")
    expect(candidates.first[:sql]).to include("FROM orders")
  end
end
