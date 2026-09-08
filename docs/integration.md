# Standalone integration

For the Rails engine, start with the [setup guide](setup.md).

KPIAssembler can also run as a Rack service and expose its workspace and JSON
API to applications written in any language.

## Start the service

Copy `.env.example` to `.env`, configure a read-only database connection, then:

```bash
bundle install
bundle exec ruby bin/kpi_assembler_web
```

The service starts at `http://127.0.0.1:9292`.

```bash
HOST=0.0.0.0
PORT=9292
KPI_DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/application
KPI_ALLOWED_ORIGIN=https://application.example
KPI_INCLUDE_TABLES=orders,customers,accounts
KPI_TENANT_COLUMN=account_id
KPI_TENANT_ID=123
```

Use a read-only database user, replica, or database copy.

## LLM provider

Gemini:

```bash
KPI_LLM_PROVIDER=gemini
GEMINI_API_KEY=your-key
KPI_GEMINI_MODEL=gemini-2.0-flash
```

Local Ollama:

```bash
KPI_LLM_PROVIDER=ollama
KPI_OLLAMA_MODEL=llama3.2:3b
KPI_OLLAMA_URL=http://localhost:11434/api/generate
```

The model only proposes definitions. Deterministic code certifies every
accepted candidate. Set `KPI_USE_LLM=false` to use heuristics only.

## Embed the workspace

```html
<script src="http://localhost:9292/kpi-assembler.js"></script>
<kpi-assembler service-url="http://localhost:9292" height="820px"></kpi-assembler>
```

## JSON API

Discover the schema and proposals:

```http
POST /api/v1/discover
Content-Type: application/json

{}
```

Certify selected proposals:

```http
POST /api/v1/certify
Content-Type: application/json

{"accepted_ids":["orders_total_sum","customers_volume"]}
```

Retrieve the latest pack:

```http
GET /api/v1/pack
```

## Production requirements

- Require authentication and authorization.
- Set a specific `KPI_ALLOWED_ORIGIN`.
- Use least-privilege, read-only database access.
- Enforce tenant isolation at both application and database boundaries.
- Persist versioned packs outside the process.
