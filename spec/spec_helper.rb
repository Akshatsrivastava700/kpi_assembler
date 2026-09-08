# frozen_string_literal: true

ENV["KPI_USE_OLLAMA"] ||= "false"

require "rspec"
require_relative "../lib/kpi_assembler"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
