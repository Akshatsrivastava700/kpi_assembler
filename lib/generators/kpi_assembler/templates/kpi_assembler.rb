# frozen_string_literal: true

KPIAssembler.configure do |config|
  # Use the host application's ActiveRecord pool. In a multi-database Rails app,
  # return the read/report pool here instead of the primary write pool.
  config.connection_provider = lambda do |_controller|
    ApplicationRecord.connected_to(role: :reading) do
      ApplicationRecord.connection_pool
    end
  end

  # Keep every generated query inside the current tenant.
  config.tenant_column = "company_id"
  config.tenant_id_resolver = lambda do |controller|
    controller.send(:current_company).id
  end

  # Optional allowlist. Leave empty so the inspector reads the live schema and
  # the LLM ranks tables that actually exist. Names must match the database
  # (people, not Person). Pin tables here only to constrain cost or tenancy.
  config.include_tables = []
  config.max_tables = 30
  config.schema_name = "public"

  # The engine inherits the host controller, including authentication and
  # authorization callbacks. This extra gate must return true.
  config.parent_controller = "ApplicationController"
  config.authorize_with = lambda do |controller|
    controller.send(:authenticate_user!)
    controller.send(:current_company).present?
  end

  # The LLM ranks discovered tables and proposes KPIs. Ruby still certifies.
  # Choose your provider (:gemini or :ollama). Set KPI_USE_LLM=false to use heuristics only.
  # Gemini: requires GEMINI_API_KEY environment variable.
  # Ollama: requires a running local daemon (e.g. `ollama serve`).
  config.llm_provider = ENV.fetch("KPI_LLM_PROVIDER", :gemini).to_sym
  config.use_llm = ENV["KPI_USE_LLM"] != "false"

  # Gemini configuration
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  config.gemini_model = ENV.fetch("KPI_GEMINI_MODEL", "gemini-2.0-flash")

  # Ollama configuration
  config.ollama_model = ENV.fetch("KPI_OLLAMA_MODEL", "llama3.2:3b")
  config.ollama_url = ENV.fetch("KPI_OLLAMA_URL", "http://localhost:11434/api/generate")
end
