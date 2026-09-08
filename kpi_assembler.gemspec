# frozen_string_literal: true

require_relative "lib/kpi_assembler/version"

Gem::Specification.new do |spec|
  spec.name = "kpi_assembler"
  spec.version = KPIAssembler::VERSION
  spec.authors = ["KPIAssembler contributors"]
  spec.summary = "Schema-driven KPI proposal and deterministic certification"
  spec.description = "A mountable Rails engine and Ruby library that proposes KPIs from application schemas and certifies their SQL before publication."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "app/**/*",
    "bin/*",
    "config/**/*",
    "docs/**/*",
    "lib/**/*",
    "public/**/*",
    "README.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # json is a Ruby default gem. Declaring it here can pull a host application onto
  # json 3.x, whose removal of `quirks_mode` breaks `render json:` on Rails 7.
  spec.add_dependency "railties", ">= 7.0", "< 8"
end
