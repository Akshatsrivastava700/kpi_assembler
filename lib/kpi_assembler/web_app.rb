# frozen_string_literal: true

require "sinatra/base"
require_relative "../kpi_assembler"
require_relative "connection"
require_relative "web_service"

module KPIAssembler
  class WebApp < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :public_folder, File.join(root, "public")
    set :static, true
    set :show_exceptions, false

    configure do
      connection = Connection.open
      include_tables = ENV.fetch("KPI_INCLUDE_TABLES", "").split(",").map(&:strip).reject(&:empty?)
      tenant_column = ENV["KPI_TENANT_COLUMN"]
      tenant_id = ENV["KPI_TENANT_ID"]

      set :web_service, WebService.new(
        db: connection,
        options: {
          llm_provider: ENV.fetch("KPI_LLM_PROVIDER", ENV["GEMINI_API_KEY"] ? "gemini" : "ollama"),
          use_llm: ENV["KPI_USE_LLM"] != "false",
          use_ollama: ENV["KPI_USE_OLLAMA"] != "false",
          ollama_model: ENV.fetch("KPI_OLLAMA_MODEL", "llama3"),
          gemini_api_key: ENV["GEMINI_API_KEY"],
          gemini_model: ENV.fetch("KPI_GEMINI_MODEL", "gemini-2.0-flash"),
          source_name: connection.label,
          include_tables: include_tables,
          max_tables: ENV["KPI_MAX_TABLES"],
          schema_name: ENV["KPI_DB_SCHEMA"],
          tenant_column: tenant_column,
          tenant_id: tenant_id && !tenant_id.empty? ? Integer(tenant_id) : nil
        }
      )
    end

    before "/api/*" do
      content_type :json
      headers(
        "Access-Control-Allow-Origin" => ENV.fetch("KPI_ALLOWED_ORIGIN", "*"),
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type, Authorization",
        "Cache-Control" => "no-store"
      )
    end

    options "/api/*" do
      204
    end

    get "/" do
      send_file File.join(settings.public_folder, "index.html")
    end

    get "/api/v1/health" do
      json(
        status: "ok",
        service: "KPIAssembler",
        version: KPIAssembler::VERSION,
        source: settings.web_service.db.label,
        dialect: settings.web_service.db.dialect,
        principle: "The LLM proposes; deterministic code certifies."
      )
    end

    post "/api/v1/discover" do
      json(settings.web_service.discover)
    end

    get "/api/v1/discover" do
      json(settings.web_service.discover)
    end

    post "/api/v1/certify" do
      payload = parse_json_body
      pack = settings.web_service.certify(payload["accepted_ids"])
      json(pack.merge(locations: settings.web_service.locations))
    end

    get "/api/v1/pack" do
      pack = settings.web_service.pack
      halt 404, json(error: "No pack has been certified yet") unless pack

      json(pack.merge(locations: settings.web_service.locations))
    end

    get "/api/v1/integration" do
      json(
        api_version: "v1",
        discovery_endpoint: "/api/v1/discover",
        certification_endpoint: "/api/v1/certify",
        pack_endpoint: "/api/v1/pack",
        embed_script: "/kpi-assembler.js",
        database_configuration: {
          url: "KPI_DATABASE_URL=postgres://user:pass@host:5432/application",
          sqlite: "KPI_DATABASE_PATH=/path/to/application.sqlite3",
          tables: "KPI_INCLUDE_TABLES=orders,customers,accounts",
          tenant: "KPI_TENANT_COLUMN=account_id KPI_TENANT_ID=123"
        }
      )
    end

    not_found do
      content_type :json if request.path.start_with?("/api/")
      json(error: "Not found", path: request.path)
    end

    error KPIAssembler::Error do
      status 422
      json(error: env["sinatra.error"].message)
    end

    error JSON::ParserError do
      status 400
      json(error: "Request body must be valid JSON")
    end

    error do
      error = env["sinatra.error"]
      warn "[KPIAssembler] #{error.class}: #{error.message}"
      status 500
      json(error: "Unexpected server error")
    end

    private

    def parse_json_body
      raw = request.body.read
      return {} if raw.empty?

      JSON.parse(raw)
    end

    def json(payload)
      JSON.generate(payload)
    end
  end
end
