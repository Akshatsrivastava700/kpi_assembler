# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require_relative "../lib/kpi_assembler/web_app"

RSpec.describe KPIAssembler::WebApp do
  include Rack::Test::Methods

  def app
    described_class
  end

  before do
    header "Host", "localhost"
  end

  def parsed_body
    JSON.parse(last_response.body)
  end

  it "serves the application UI and framework-neutral embed script" do
    get "/"
    expect(last_response).to be_ok
    expect(last_response.body).to include("Turn application data into")

    get "/kpi-assembler.js"
    expect(last_response).to be_ok
    expect(last_response.body).to include('customElements.define("kpi-assembler"')
  end

  it "exposes service health" do
    get "/api/v1/health"
    expect(last_response).to be_ok
    expect(parsed_body.fetch("principle")).to include("deterministic code certifies")
  end

  it "discovers candidates and certifies only selected IDs" do
    post "/api/v1/discover", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response).to be_ok
    ids = parsed_body.fetch("candidates").map { |candidate| candidate.fetch("id") }
    expect(ids).to include("lead_conversion_rate", "revenue_per_lead_unsafe")
    expect(parsed_body.fetch("proposer")).to eq("heuristics")

    post(
      "/api/v1/certify",
      JSON.generate(accepted_ids: %w[lead_conversion_rate revenue_per_lead_unsafe]),
      { "CONTENT_TYPE" => "application/json" }
    )
    expect(last_response).to be_ok
    expect(parsed_body.fetch("kpis").map { |kpi| kpi.fetch("id") }).to eq(["lead_conversion_rate"])
    expect(parsed_body.fetch("drafts").first.fetch("reasons").join).to include("JOIN without ON")

    get "/api/v1/pack"
    expect(last_response).to be_ok
    expect(parsed_body.fetch("locations").length).to eq(3)
  end

  it "returns a useful validation error when nothing is selected" do
    post "/api/v1/discover", "{}", { "CONTENT_TYPE" => "application/json" }
    post "/api/v1/certify", JSON.generate(accepted_ids: []), { "CONTENT_TYPE" => "application/json" }

    expect(last_response.status).to eq(422)
    expect(parsed_body.fetch("error")).to include("Select at least one KPI")
  end
end
