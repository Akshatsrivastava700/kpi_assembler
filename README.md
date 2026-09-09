# KPIAssembler

<img width="1920" height="903" alt="Screenshot from 2026-09-09 15-51-19" src="https://github.com/user-attachments/assets/a11d4833-8bf1-4315-b6cb-9203cf65cea4" />


KPIAssembler discovers application schemas, proposes business metrics, and
certifies generated SQL before a number is trusted.

The LLM proposes. Deterministic code certifies.

## Install (Rails)

```ruby
# Gemfile
gem "kpi_assembler", "~> 0.5"
```

```bash
bundle install
bin/rails generate kpi_assembler:install
```

```ruby
# config/routes.rb
mount KPIAssembler::Engine => "/kpi-assembler"
```

Then:

1. Edit `config/initializers/kpi_assembler.rb` (database pool, tenant, auth).
2. Set `GEMINI_API_KEY` and `KPI_LLM_PROVIDER=gemini` in the host `.env`,
   or use Ollama / `KPI_USE_LLM=false`.
3. Restart the app and open `/kpi-assembler`.

Full walkthrough, env vars, and troubleshooting:
**[Setup guide](docs/setup.md)**.

Rails engine details: [docs/rails-engine.md](docs/rails-engine.md).
Standalone Rack/CLI/API: [docs/integration.md](docs/integration.md).

## What it does

1. **Discover** — introspect tables, columns, and foreign keys
2. **Propose** — Gemini, Ollama, or schema heuristics draft KPI SQL
3. **Accept** — you choose which candidates to certify
4. **Certify** — read-only SELECT, join safety, tenant scope, planner, sample run
5. **Publish** — certified pack as JSON (and HTML from the CLI)

Rejected candidates never reach certification. **Draft** means a selected KPI
failed a certification check.

## Requirements

- Ruby >= 3.0
- Rails 7 for the engine
- Read-only database access (replica or reporting user)

## License

MIT
