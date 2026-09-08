# Setup guide

KPIAssembler inspects your application schema, proposes KPI definitions, and
certifies their SQL before anything is published. The model only proposes.
Deterministic Ruby certifies.

There are two install paths:

1. **Rails engine** — mount the workspace inside an existing Rails 7 app
2. **Standalone service** — run the Rack UI/API next to any application

Most teams should use the Rails engine.

## Requirements

- Ruby 3.0 or newer
- Rails 7.x for the engine (`railties >= 7.0, < 8`)
- A **read-only** database user, replica, or reporting pool
- Optional: a [Gemini API key](https://aistudio.google.com/apikey) or a local
  [Ollama](https://ollama.com) daemon

Do not point certification at a production write primary.

## Rails engine

### 1. Add the gem

```ruby
# Gemfile
gem "kpi_assembler", "~> 0.5"
```

```bash
bundle install
bin/rails generate kpi_assembler:install
```

The generator writes `config/initializers/kpi_assembler.rb`.

### 2. Mount the workspace

In `config/routes.rb`, mount inside whatever scope already requires a signed-in
user:

```ruby
mount KPIAssembler::Engine => "/kpi-assembler"
```

Open `/kpi-assembler` after signing in.

JSON endpoints:

```text
GET/POST /kpi-assembler/api/v1/discover
POST     /kpi-assembler/api/v1/certify
GET      /kpi-assembler/api/v1/pack
```

### 3. Edit the initializer

Replace the sample hooks with your app's connection, tenant, and auth.

```ruby
KPIAssembler.configure do |config|
  # Prefer a read/report pool, not the write primary.
  config.connection_provider = lambda do |_controller|
    ApplicationRecord.connected_to(role: :reading) do
      ApplicationRecord.connection_pool
    end
  end

  config.parent_controller = "ApplicationController"

  # Column that exists on fact tables. Omit tenant_column if you have none.
  config.tenant_column = "account_id"
  config.tenant_id_resolver = lambda do |controller|
    controller.send(:current_account).id
  end

  # Empty allowlist = inspect the live schema (up to max_tables).
  # Names must match the database (people, not Person).
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
  config.ollama_url = ENV.fetch("KPI_OLLAMA_URL", "http://localhost:11434/api/generate")
end
```

If you have no `reading` role, return `ActiveRecord::Base.connection_pool`
(still with a read-only user).

### 4. Set environment variables

Put secrets in the host app `.env` (or your secret manager). Do not commit keys.

**Gemini (cloud):**

```bash
KPI_LLM_PROVIDER=gemini
GEMINI_API_KEY=your-key
KPI_GEMINI_MODEL=gemini-2.0-flash
```

You do not set a Gemini URL. The default endpoint is built from the model name.

**Ollama (local):**

```bash
KPI_LLM_PROVIDER=ollama
KPI_OLLAMA_MODEL=llama3.2:3b
KPI_OLLAMA_URL=http://localhost:11434/api/generate
```

Start the daemon first: `ollama serve`, then `ollama pull llama3.2:3b`.

**Heuristics only:**

```bash
KPI_USE_LLM=false
```

Restart `bin/rails server` after changing env vars or the initializer.

### 5. First run

1. Sign in and open `/kpi-assembler`.
2. Click **Discover metrics**. Schema cards and candidate KPIs should appear.
3. Select the definitions you want. Rejected items never reach certification.
4. Click **Certify**. Certified KPIs become the pack. Failures land in **draft**
   with reasons (unsafe SQL, missing tenant scope, planner error, NULL sample
   replay). Draft is not the same as rejecting a KPI in the UI.

The workspace shows whether the proposer was `llm` or `heuristics`, the model
name, and any tables the model ranked.

## Configuration reference

| Setting | Purpose |
| --- | --- |
| `connection_provider` | Returns an AR pool or connection used for inspect + certify |
| `tenant_column` / `tenant_id_resolver` | Injects tenant filters into generated SQL |
| `include_tables` | Optional allowlist. Empty means inspect the live schema |
| `max_tables` | Cap after ranking; omitted tables are reported in the UI |
| `schema_name` | PostgreSQL schema (default `public`) |
| `parent_controller` | Host controller the engine inherits (auth callbacks) |
| `authorize_with` | Extra gate; must not return `false` |
| `llm_provider` | `:gemini` or `:ollama` |
| `use_llm` | `false` skips the model and uses schema heuristics |
| `gemini_api_key` / `gemini_model` | Gemini credentials |
| `ollama_model` / `ollama_url` | Local Ollama |

Environment variables the gem reads: `KPI_LLM_PROVIDER`, `KPI_USE_LLM`,
`GEMINI_API_KEY`, `KPI_GEMINI_MODEL`, `KPI_GEMINI_URL`, `KPI_OLLAMA_MODEL`,
`KPI_OLLAMA_URL`, `KPI_USE_OLLAMA` (Ollama-only off switch).

## Standalone service

Use this when the host app is not Rails, or you want a separate process.

```bash
gem install kpi_assembler
# or clone the repo and: bundle install
```

From the gem source checkout:

```bash
cp .env.example .env
# set KPI_DATABASE_URL or KPI_DATABASE_PATH, plus LLM vars
bundle exec ruby bin/kpi_assembler_web
```

Opens `http://127.0.0.1:9292`.

Useful env vars:

```bash
HOST=0.0.0.0
PORT=9292
KPI_DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/application
KPI_DATABASE_PATH=/absolute/path/to/application.sqlite3
KPI_INCLUDE_TABLES=orders,customers,accounts
KPI_TENANT_COLUMN=account_id
KPI_TENANT_ID=123
KPI_ALLOWED_ORIGIN=https://your-app.example
KPI_LLM_PROVIDER=gemini
GEMINI_API_KEY=your-key
```

Embed:

```html
<script src="http://localhost:9292/kpi-assembler.js"></script>
<kpi-assembler service-url="http://localhost:9292" height="820px"></kpi-assembler>
```

CLI against the sample database:

```bash
bundle exec ruby bin/kpi_assembler --sample-db
```

See [standalone integration](integration.md) for the JSON API.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Discover does nothing / non-JSON error | Host redirected to login. Send the request while signed in. Confirm `/kpi-assembler/assets/app.js` returns 200. |
| `heuristics` proposer, Gemini fallback | `GEMINI_API_KEY` missing or HTTP error. The UI shows `proposer_fallback`. |
| `heuristics` proposer, Ollama fallback | `ollama serve` not running, or model not pulled. Fallback text names installed models. |
| UI does not show tables you added | `include_tables` names must match the DB. Check `missing_tables` / `omitted_tables` (`max_tables`). |
| Many KPIs become **draft** after certify | Open `reasons`. Common: missing `tenant_column = id`, invented tables, `NULLIF` producing NULL on empty windows. |
| `json` / `quirks_mode` on Rails 7 | Pin `gem "json", "< 3"` in the **host** Gemfile. |
| Slow or truncated LLM output | Lower `max_tables`, or use `gemini-2.0-flash` / a small Ollama model. |

## Security

- Authorize the mount the same way as the rest of the app. The extra
  `authorize_with` gate is not a substitute for a real permission check.
- Certification **executes** candidate `SELECT`s. Use a least-privilege
  read-only role.
- Tenant SQL is only injected when `tenant_column` exists on the fact table.
- The latest pack is kept in process memory per tenant. Persist packs yourself
  before relying on this in production.
