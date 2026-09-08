# Rails Engine integration

KPIAssembler is a mountable Rails Engine. It uses the host application's
session, authorization, and Active Record connection pool.

## Install

```ruby
gem "kpi_assembler"
```

```bash
bundle install
bin/rails generate kpi_assembler:install
```

The generator creates `config/initializers/kpi_assembler.rb`.

## Configure

```ruby
KPIAssembler.configure do |config|
  config.connection_provider = lambda do |_controller|
    ApplicationRecord.connected_to(role: :reading) do
      ApplicationRecord.connection_pool
    end
  end

  config.parent_controller = "ApplicationController"
  config.tenant_column = "account_id"
  config.tenant_id_resolver = lambda do |controller|
    controller.send(:current_account).id
  end

  config.include_tables = []
  config.max_tables = 30
  config.schema_name = "public"

  config.authorize_with = lambda do |controller|
    controller.send(:authenticate_user!)
    controller.send(:current_account).present?
  end

  config.llm_provider = ENV.fetch("KPI_LLM_PROVIDER", "gemini").to_sym
  config.use_llm = ENV["KPI_USE_LLM"] != "false"

  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  config.gemini_model = ENV.fetch("KPI_GEMINI_MODEL", "gemini-2.0-flash")

  config.ollama_model = ENV.fetch("KPI_OLLAMA_MODEL", "llama3.2:3b")
  config.ollama_url = ENV.fetch(
    "KPI_OLLAMA_URL",
    "http://localhost:11434/api/generate"
  )
end
```

Store secrets in the host application's environment rather than the initializer:

```bash
KPI_LLM_PROVIDER=gemini
GEMINI_API_KEY=your-key
KPI_GEMINI_MODEL=gemini-2.0-flash
```

Restart the Rails server after changing environment variables.

## Mount

Add the engine to `config/routes.rb`:

```ruby
mount KPIAssembler::Engine => "/kpi-assembler"
```

The mounted endpoints are:

```text
GET/POST /kpi-assembler/api/v1/discover
POST     /kpi-assembler/api/v1/certify
GET      /kpi-assembler/api/v1/pack
```

## Production guidance

Point `connection_provider` at a read-only pool. Replace the example
authorization callback with the host application's permission policy. Tenant
scoping must correspond to real columns in the inspected tables.

The engine currently keeps the latest pack in process memory per tenant.
Production applications should persist versioned packs and define an
invalidation policy.
