# frozen_string_literal: true

require "rails/generators"

module KPIAssembler
  module Generators
    class InstallGenerator < Rails::Generators::Base
      # `KpiAssembler` is an alias of `KPIAssembler`, which Rails would
      # otherwise expose as `k_p_i_assembler:install`.
      namespace "kpi_assembler:install"

      desc "Creates config/initializers/kpi_assembler.rb in the host application."
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "kpi_assembler.rb", "config/initializers/kpi_assembler.rb"
      end

      def print_mount_instruction
        say "\nMount KPIAssembler in config/routes.rb:", :green
        say '  mount KPIAssembler::Engine => "/kpi-assembler"'
        say "\nThen set GEMINI_API_KEY (or KPI_LLM_PROVIDER=ollama) and restart."
        say "Setup guide: https://github.com/Akshatsrivastava700/kpi_assembler/blob/main/docs/setup.md"
      end
    end
  end
end
