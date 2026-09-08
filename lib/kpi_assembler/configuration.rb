# frozen_string_literal: true

require "thread"

module KPIAssembler
  class Configuration
    attr_accessor :connection_provider,
                  :tenant_id_resolver,
                  :authorize_with,
                  :include_tables,
                  :max_tables,
                  :schema_name,
                  :tenant_column,
                  :llm_provider,
                  :use_llm,
                  :use_ollama,
                  :ollama_model,
                  :ollama_url,
                  :gemini_api_key,
                  :gemini_model,
                  :gemini_url,
                  :parent_controller

    def initialize
      @connection_provider = lambda do |_controller|
        ActiveRecord::Base.connection_pool
      end
      @tenant_id_resolver = ->(_controller) {}
      @authorize_with = lambda do |controller|
        controller.send(:authenticate_user!) if controller.respond_to?(:authenticate_user!, true)
        true
      end
      @include_tables = []
      @max_tables = 30
      @schema_name = "public"
      @tenant_column = nil
      @llm_provider = ENV.fetch("KPI_LLM_PROVIDER", ENV["GEMINI_API_KEY"] ? "gemini" : "ollama").to_sym
      @use_ollama = ENV["KPI_USE_OLLAMA"] != "false"
      @use_llm = ENV["KPI_USE_LLM"] != "false"
      @ollama_model = ENV.fetch("KPI_OLLAMA_MODEL", "llama3")
      @ollama_url = ENV.fetch("KPI_OLLAMA_URL", "http://localhost:11434/api/generate")
      @gemini_api_key = ENV["GEMINI_API_KEY"]
      @gemini_model = ENV.fetch("KPI_GEMINI_MODEL", "gemini-2.0-flash")
      @gemini_url = ENV["KPI_GEMINI_URL"]
      @parent_controller = "ApplicationController"
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      reset_services!
    end

    def reset_configuration!
      @configuration = Configuration.new
      reset_services!
    end

    def service_for(controller)
      tenant_id = invoke(configuration.tenant_id_resolver, controller)
      source = invoke(configuration.connection_provider, controller)
      connection = Connection.wrap(source, label: "Rails application database")
      key = [connection.cache_key, tenant_id]

      services_mutex.synchronize do
        services[key] ||= WebService.new(
          db: connection,
          options: {
            source_name: connection.label,
            include_tables: Array(configuration.include_tables),
            max_tables: configuration.max_tables,
            schema_name: configuration.schema_name,
            tenant_column: configuration.tenant_column,
            tenant_id: tenant_id,
            llm_provider: configuration.llm_provider,
            use_llm: configuration.use_llm,
            use_ollama: configuration.use_ollama,
            ollama_model: configuration.ollama_model,
            ollama_url: configuration.ollama_url,
            gemini_api_key: configuration.gemini_api_key,
            gemini_model: configuration.gemini_model,
            gemini_url: configuration.gemini_url
          }
        )
      end
    end

    def authorized?(controller)
      configuration.authorize_with.nil? || invoke(configuration.authorize_with, controller) != false
    end

    def reset_services!
      @services = {}
    end

    private

    def services
      @services ||= {}
    end

    def services_mutex
      @services_mutex ||= Mutex.new
    end

    def invoke(callable, controller)
      callable.arity.zero? ? callable.call : callable.call(controller)
    end
  end
end
