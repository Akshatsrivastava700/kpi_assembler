# frozen_string_literal: true

module KPIAssembler
  class ApplicationController < KPIAssembler.configuration.parent_controller.constantize
    before_action :authorize_kpi_assembler!

    private

    def authorize_kpi_assembler!
      return if KPIAssembler.authorized?(self)

      head :forbidden
    end

    def kpi_service
      KPIAssembler.service_for(self)
    end
  end
end
