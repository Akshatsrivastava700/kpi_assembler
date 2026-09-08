# frozen_string_literal: true

require "rails/engine"

module KPIAssembler
  class Engine < ::Rails::Engine
    isolate_namespace KPIAssembler

    # Without this the names derived from `KPIAssembler` are `k_p_i_assembler`.
    engine_name "kpi_assembler"
    railtie_name "kpi_assembler"
  end
end

# Rails camelizes the `kpi_assembler` path segment of engine controllers as
# `KpiAssembler`. Defining an acronym inflection instead would change how the
# host application resolves its own `Kpi` constants.
KpiAssembler = KPIAssembler unless defined?(KpiAssembler)
