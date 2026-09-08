# frozen_string_literal: true

module KPIAssembler
  module Api
    module V1
      class WorkspaceController < KPIAssembler::ApplicationController
        skip_forgery_protection

        rescue_from KPIAssembler::Error, with: :unprocessable_entity
        rescue_from JSON::ParserError, with: :invalid_json

        def health
          render json: {
            status: "ok",
            service: "KPIAssembler",
            version: KPIAssembler::VERSION,
            source: kpi_service.db.label,
            dialect: kpi_service.db.dialect,
            principle: "The LLM proposes; deterministic code certifies."
          }
        end

        def discover
          render json: kpi_service.discover
        end

        def certify
          pack = kpi_service.certify(request_payload["accepted_ids"])
          render json: pack.merge(locations: kpi_service.locations)
        end

        def pack
          value = kpi_service.pack
          return render json: { error: "No pack has been certified yet" }, status: :not_found unless value

          render json: value.merge(locations: kpi_service.locations)
        end

        def integration
          render json: {
            api_version: "v1",
            mount_path: request.script_name,
            discovery_endpoint: api_v1_discover_path,
            certification_endpoint: api_v1_certify_path,
            pack_endpoint: api_v1_pack_path
          }
        end

        private

        def request_payload
          return {} if request.raw_post.empty?

          JSON.parse(request.raw_post)
        end

        def unprocessable_entity(error)
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def invalid_json
          render json: { error: "Request body must be valid JSON" }, status: :bad_request
        end
      end
    end
  end
end
