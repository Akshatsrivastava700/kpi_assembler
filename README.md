# KPIAssembler

KPIAssembler discovers application schemas, proposes useful business metrics,
and deterministically certifies generated SQL before publishing a KPI pack.

The LLM proposes; deterministic code certifies. Candidate queries are checked
against the real schema, tenant boundary, SQL safety rules, query planner, and
sample execution before they can be marked certified.

## Features

- Mountable Rails Engine with an interactive workspace and JSON API
- Standalone Rack application and command-line interface
- SQLite and PostgreSQL schema introspection
- Gemini and Ollama KPI proposal providers
- Schema-driven heuristic fallback when no model is available
- Deterministic SQL, join, division, tenant, and execution checks
- JSON and HTML KPI packs

## Install

Add the gem to your application:

```ruby
gem "kpi_assembler"
```

Then run:

```bash
bundle install
bin/rails generate kpi_assembler:install
```

Mount the engine:

```ruby
mount KPIAssembler::Engine => "/kpi-assembler"
```

See [Rails Engine integration](docs/rails-engine.md) for configuration and
[standalone integration](docs/integration.md) for Rack, CLI, and API usage.

## LLM configuration

Gemini:

```bash
KPI_LLM_PROVIDER=gemini
GEMINI_API_KEY=your-key
KPI_GEMINI_MODEL=gemini-2.0-flash
```

Ollama:

```bash
KPI_LLM_PROVIDER=ollama
KPI_OLLAMA_MODEL=llama3.2:3b
KPI_OLLAMA_URL=http://localhost:11434/api/generate
```

Set `KPI_USE_LLM=false` to use schema-driven heuristics only.

## Development

```bash
bundle install
bundle exec rspec
bundle exec ruby bin/kpi_assembler --sample-db
bundle exec ruby bin/kpi_assembler_web
```

The standalone workspace starts at `http://127.0.0.1:9292`.

## Security

Use a read-only database user or replica. Generated candidate SQL is executed
during deterministic certification. Configure tenant scoping and authorization
before exposing the engine or API.

## License

MIT
