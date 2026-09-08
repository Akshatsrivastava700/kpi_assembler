# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe KPIAssembler::Pipeline do
  it "runs the default acceptance path and leaves the unsafe metric as draft" do
    db = KPIAssembler::SampleDatabase.build
    pack = described_class.new(db_connection: db, options: { demo: true }).run

    expect(pack[:kpis].map { |k| k[:id] }).to include("lead_conversion_rate", "paid_mrr")
    expect(pack[:kpis].map { |k| k[:id] }).not_to include("revenue_per_lead_unsafe")
    expect(pack[:drafts].map { |k| k[:id] }).to include("revenue_per_lead_unsafe")
    expect(pack[:briefing][:headline]).not_to be_empty
    expect(pack[:evaluations]["all"]).to include("lead_conversion_rate")
  end

  it "writes json and html outputs" do
    db = KPIAssembler::SampleDatabase.build
    pipeline = described_class.new(db_connection: db)
    pack = pipeline.run
    Dir.mktmpdir do |dir|
      json_path, html_path = pipeline.write_outputs!(pack, dir)
      expect(File.exist?(json_path)).to be true
      html = File.read(html_path)
      expect(html).to include("draft")
      expect(html).to include("Weekly briefing")
    end
  end
end
