# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require_relative "../lib/kpi_assembler/engine"

class ApplicationController < ActionController::Base; end unless defined?(ApplicationController)

RSpec.describe "Rails integration" do
  class FakeActiveRecordConnection
    def initialize(database)
      @database = database
    end

    def adapter_name
      "SQLite"
    end

    attr_reader :database
    alias raw_connection database
  end

  class FakeActiveRecordPool
    def initialize(database)
      @connection = FakeActiveRecordConnection.new(database)
    end

    def with_connection
      yield @connection
    end
  end

  it "wraps an ActiveRecord connection pool without holding a checked-out connection" do
    database = KPIAssembler::SampleDatabase.build
    connection = KPIAssembler::Connection.wrap(FakeActiveRecordPool.new(database))

    expect(connection.dialect).to eq("SQLite")
    expect(connection.execute("SELECT COUNT(*) FROM leads").dig(0, 0)).to eq(180)
  end

  it "exposes mountable engine routes" do
    require_relative "../app/controllers/kpi_assembler/application_controller"
    require_relative "../app/controllers/kpi_assembler/api/v1/workspace_controller"
    load KPIAssembler::Engine.root.join("config/routes.rb")
    route = KPIAssembler::Engine.routes.recognize_path("/api/v1/discover", method: :post)
    expect(route).to include(controller: "kpi_assembler/api/v1/workspace", action: "discover")
  end

  it "requires tenant scope during certification when configured" do
    db = KPIAssembler::SampleDatabase.build
    schema = KPIAssembler::SchemaInspector.new(db).introspect
    candidate = KPIAssembler::SchemaKpiProposer.new(
      schema,
      tenant_column: "location_id",
      tenant_id: 2
    ).propose.find { |kpi| kpi[:id] == "lead_conversion_rate" }

    expect(candidate[:sql]).to include("location_id = 2")
    certified, drafts = KPIAssembler::CertificationEngine.new(
      db,
      schema,
      tenant_column: "location_id",
      tenant_id: 2
    ).certify([candidate])
    expect(certified.length).to eq(1)
    expect(drafts).to be_empty
  end
end
