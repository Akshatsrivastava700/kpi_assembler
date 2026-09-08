# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe KPIAssembler::Env do
  it "loads KEY=VALUE pairs without overriding existing ENV" do
    ENV["KPI_ENV_SPEC_EXISTING"] = "keep-me"
    file = Tempfile.new("kpi-env")
    file.write(<<~ENV)
      KPI_ENV_SPEC_EXISTING=from-file
      KPI_ENV_SPEC_NEW=from-file
      # comment
      KPI_ENV_SPEC_QUOTED="quoted value"
    ENV
    file.flush

    described_class.load!(file.path)

    expect(ENV["KPI_ENV_SPEC_EXISTING"]).to eq("keep-me")
    expect(ENV["KPI_ENV_SPEC_NEW"]).to eq("from-file")
    expect(ENV["KPI_ENV_SPEC_QUOTED"]).to eq("quoted value")
  ensure
    %w[KPI_ENV_SPEC_EXISTING KPI_ENV_SPEC_NEW KPI_ENV_SPEC_QUOTED].each { |key| ENV.delete(key) }
    file.close!
  end
end
