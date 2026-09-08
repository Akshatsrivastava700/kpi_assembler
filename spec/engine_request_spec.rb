# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "rack/test"
require "tmpdir"
require_relative "../lib/kpi_assembler/engine"

class HostApplicationController < ActionController::Base
  # Stands in for a host app whose callbacks reject requests the engine's static
  # assets must not be subject to (Rails raises this for `.js` responses inside
  # the forgery-protection chain).
  before_action :reject_javascript_requests

  def current_company
    Struct.new(:id).new(1)
  end

  private

  def reject_javascript_requests
    return unless request.path.end_with?(".js")

    raise ActionController::InvalidCrossOriginRequest, "blocked by host application"
  end
end

module HostApp
  class Application < Rails::Application
    # The host app must not share a root with the gem, or the engine's own
    # config/routes.rb would also be loaded as the application's routes.
    config.root = Dir.mktmpdir("kpi-assembler-host")
    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "kpi-assembler-test-secret"
    config.logger = Logger.new(IO::NULL)
    config.hosts.clear
  end
end

RSpec.describe "Mounted engine requests" do
  include Rack::Test::Methods

  before(:all) do
    sample = KPIAssembler::SampleDatabase.build

    KPIAssembler.configure do |config|
      config.parent_controller = "HostApplicationController"
      config.connection_provider = ->(_controller) { sample }
      config.tenant_id_resolver = ->(controller) { controller.send(:current_company).id }
      config.authorize_with = ->(_controller) { true }
      config.tenant_column = nil
      config.use_llm = false
      config.use_ollama = false
    end

    HostApp::Application.initialize!
    Rails.application.routes.draw do
      mount KPIAssembler::Engine => "/kpi-assembler"
    end
  end

  after(:all) { KPIAssembler.reset_configuration! }

  def app
    Rails.application
  end

  def parsed_body
    JSON.parse(last_response.body)
  end

  it "serves the workspace HTML with mount-aware asset and API paths" do
    get "/kpi-assembler"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('content="/kpi-assembler/api/v1"')
    expect(last_response.body).to include('href="/kpi-assembler/assets/app.css"')
    expect(last_response.body).to include('src="/kpi-assembler/assets/app.js"')
  end

  it "serves the JavaScript that wires up the Discover button" do
    get "/kpi-assembler/assets/app.js"

    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to include("text/javascript")
    expect(last_response.body).to include("discover-button")
  end

  it "serves the stylesheet" do
    get "/kpi-assembler/assets/app.css"

    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to include("text/css")
  end

  it "does not serve arbitrary files from the gem" do
    get "/kpi-assembler/assets/index.html"
    expect(last_response.status).to eq(404)

    get "/kpi-assembler/assets/../lib/kpi_assembler.rb"
    expect(last_response.status).to eq(404)
  end

  it "reuses one service when the host hands back a fresh connection each request" do
    original = KPIAssembler.configuration.connection_provider
    sample = KPIAssembler::SampleDatabase.build
    KPIAssembler.configure do |config|
      config.connection_provider = ->(_controller) { KPIAssembler::Connection.wrap(sample) }
    end

    controller = HostApplicationController.new
    first = KPIAssembler.service_for(controller)
    second = KPIAssembler.service_for(controller)

    expect(second).to be(first)
  ensure
    KPIAssembler.configure { |config| config.connection_provider = original }
  end

  it "certifies even when this process never served the discover request" do
    service = KPIAssembler::WebService.new(db: KPIAssembler::SampleDatabase.build)

    pack = service.certify(%w[lead_conversion_rate])

    expect(pack.fetch(:kpis).map { |kpi| kpi.fetch(:id) }).to eq(["lead_conversion_rate"])
  end

  it "reports configured tables that the database does not have" do
    service = KPIAssembler::WebService.new(
      db: KPIAssembler::SampleDatabase.build,
      options: { include_tables: %w[invoices no_such_table] }
    )

    result = service.discover

    expect(result.fetch(:tables).map { |table| table.fetch(:name) }).to eq(["invoices"])
    expect(result.fetch(:missing_tables)).to eq(["no_such_table"])
  end

  it "reports nothing missing when every configured table exists" do
    service = KPIAssembler::WebService.new(
      db: KPIAssembler::SampleDatabase.build,
      options: { include_tables: %w[invoices leads] }
    )

    expect(service.discover.fetch(:missing_tables)).to be_empty
  end

  it "reports tables dropped by the max_tables budget" do
    service = KPIAssembler::WebService.new(
      db: KPIAssembler::SampleDatabase.build,
      options: { max_tables: 2 }
    )

    result = service.discover

    expect(result.fetch(:tables).length).to eq(2)
    expect(result.fetch(:omitted_tables)).not_to be_empty
    expect(result.fetch(:tables).map { |table| table.fetch(:name) } + result.fetch(:omitted_tables))
      .to match_array(%w[appointments invoices leads locations memberships])
  end

  it "still rejects an empty selection" do
    service = KPIAssembler::WebService.new(db: KPIAssembler::SampleDatabase.build)

    expect { service.certify([]) }
      .to raise_error(KPIAssembler::Error, /Select at least one KPI/)
  end

  it "discovers and certifies through the mounted API" do
    post "/kpi-assembler/api/v1/discover", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(200)
    ids = parsed_body.fetch("candidates").map { |candidate| candidate.fetch("id") }
    expect(ids).to include("lead_conversion_rate")

    post(
      "/kpi-assembler/api/v1/certify",
      JSON.generate(accepted_ids: %w[lead_conversion_rate revenue_per_lead_unsafe]),
      { "CONTENT_TYPE" => "application/json" }
    )
    expect(last_response.status).to eq(200)
    expect(parsed_body.fetch("kpis").map { |kpi| kpi.fetch("id") }).to eq(["lead_conversion_rate"])
    expect(parsed_body.fetch("drafts").length).to eq(1)
  end
end
