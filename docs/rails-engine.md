# Rails Engine notes

Use this after the [setup guide](setup.md). KPIAssembler mounts inside a Rails 7
app, reuses the host session, and reads through Active Record.

## Generator

```bash
bundle install
bin/rails generate kpi_assembler:install
```

Creates `config/initializers/kpi_assembler.rb`. The template uses
`current_company` / `company_id` as placeholders — change them to match your
app (`current_account`, `tenant_id`, and so on).

## Routes

```ruby
mount KPIAssembler::Engine => "/kpi-assembler"
```

```text
GET/POST /kpi-assembler/api/v1/discover
POST     /kpi-assembler/api/v1/certify
GET      /kpi-assembler/api/v1/pack
```

Static UI files are served at `/kpi-assembler/assets/*` outside the host
controller stack so JavaScript is not blocked as a cross-origin response.

## Connection

`connection_provider` must return a pool or connection `KPIAssembler::Connection`
can wrap: `ActiveRecord::Base.connection_pool`, another pool, or a wrapped
adapter. Prefer `connected_to(role: :reading)` when the host has a replica.

## Tenancy

If `tenant_column` is set and that column exists on a fact table, every
certified query on that table must include `column = tenant_id`. Gemini often
omits this; certification then marks the KPI draft.

## Packs

The engine stores the latest pack in memory per tenant. Restarting the process
clears it. Persist packs in the host app before production use.
