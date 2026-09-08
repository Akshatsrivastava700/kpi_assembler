# frozen_string_literal: true

require_relative "connection"

module KPIAssembler
  class SchemaInspector
    SKIP_TABLES = %w[
      schema_migrations ar_internal_metadata delayed_jobs versions
      audits audits_archive sessions pghero_space_stats
      oauth_access_grants oauth_access_tokens oauth_applications
      ckeditor_assets friendly_id_slugs data_migrations completed_jobs
      killed_queries old_passwords permissions
    ].freeze

    SKIP_PREFIXES = %w[club_os_ abc_ mb_ pg_].freeze

    attr_reader :db, :options

    # Configured tables that the database does not actually expose. Populated by
    # #introspect so a typo or a wrong schema surfaces instead of silently
    # narrowing discovery to nothing.
    attr_reader :missing_tables

    # Tables that exist but were cut by the max_tables budget.
    attr_reader :omitted_tables

    def initialize(db, options = {})
      @db = Connection.wrap(db)
      @options = options
      @missing_tables = []
      @omitted_tables = []
    end

    def introspect
      tables = selected_tables
      tables.each_with_object({}) do |table, schema|
        quoted = db.quote_ident(table)
        columns = columns_for(table)
        row_count = row_count_for(table, quoted)
        schema[table] = {
          columns: columns,
          foreign_keys: foreign_keys_for(table),
          row_count: row_count,
          time_columns: columns.select { |col| time_column?(col) }.map { |col| col[:name] },
          categorical_values: profile_categoricals(quoted, columns, row_count),
          sample_rows: sample_rows_for(quoted, row_count)
        }
      end
    end

    private

    def selected_tables
      names = all_tables
      include_list = Array(options[:include_tables]).map(&:to_s).reject(&:empty?)
      @missing_tables = include_list - names

      names = names.select { |name| include_list.include?(name) } unless include_list.empty?
      names = names.reject { |name| skip_table?(name) } if include_list.empty?

      limit = Integer(options[:max_tables].to_s.empty? ? ENV.fetch("KPI_MAX_TABLES", "30") : options[:max_tables])
      return names if names.size <= limit

      ranked = names.sort_by { |name| -table_score(name) }
      @omitted_tables = ranked.drop(limit).sort
      ranked.first(limit)
    end

    def all_tables
      if db.sqlite?
        db.execute(<<~SQL).flatten
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
          ORDER BY name
        SQL
      else
        schema_name = options[:schema_name] || ENV.fetch("KPI_DB_SCHEMA", "public")
        db.execute(
          "SELECT tablename FROM pg_tables WHERE schemaname = ? ORDER BY tablename",
          [schema_name]
        ).flatten
      end
    end

    def skip_table?(name)
      return true if SKIP_TABLES.include?(name)
      return true if SKIP_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      return true if name.end_with?("_archive", "_summary", "_caches")

      false
    end

    def table_score(name)
      score = 0
      score += 10 if name.match?(/people|leads|members|customers|accounts/)
      score += 8 if name.match?(/activit|appoint|event|tours|visits/)
      score += 8 if name.match?(/invoice|payment|order|sale|revenue/)
      score += 6 if name.match?(/compan|location|site|club/)
      score += 4 if name.match?(/membership|subscription/)
      score
    end

    def columns_for(table)
      if db.sqlite?
        db.execute("PRAGMA table_info(#{db.quote_ident(table)})").map do |col|
          {
            cid: col[0],
            name: col[1],
            type: col[2],
            notnull: col[3],
            dflt_value: col[4],
            pk: col[5]
          }
        end
      else
        rows = db.execute(<<~SQL, [options[:schema_name] || "public", table])
          SELECT ordinal_position, column_name, data_type, is_nullable, column_default
          FROM information_schema.columns
          WHERE table_schema = ? AND table_name = ?
          ORDER BY ordinal_position
        SQL
        rows.map do |row|
          {
            cid: row[0].to_i,
            name: row[1],
            type: row[2],
            notnull: row[3] == "NO" ? 1 : 0,
            dflt_value: row[4],
            pk: row[1] == "id" ? 1 : 0
          }
        end
      end
    end

    def foreign_keys_for(table)
      if db.sqlite?
        db.execute("PRAGMA foreign_key_list(#{db.quote_ident(table)})").map do |fk|
          { id: fk[0], seq: fk[1], table: fk[2], from: fk[3], to: fk[4] }
        end
      else
        rows = db.execute(<<~SQL, [options[:schema_name] || "public", table])
          SELECT kcu.column_name, ccu.table_name, ccu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
           AND tc.table_schema = kcu.table_schema
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_name = tc.constraint_name
           AND ccu.table_schema = tc.table_schema
          WHERE tc.constraint_type = 'FOREIGN KEY'
            AND tc.table_schema = ?
            AND tc.table_name = ?
        SQL
        rows.each_with_index.map do |row, index|
          { id: index, seq: 0, table: row[1], from: row[0], to: row[2] }
        end
      end
    end

    def row_count_for(table, quoted)
      if db.postgres?
        estimate = db.execute("SELECT n_live_tup FROM pg_stat_user_tables WHERE relname = ?", [table]).dig(0, 0)
        return estimate.to_i if estimate
      end
      db.execute("SELECT COUNT(*) FROM #{quoted}").dig(0, 0).to_i
    rescue StandardError
      0
    end

    def sample_rows_for(quoted, row_count)
      return [] if row_count > 50_000

      db.execute("SELECT * FROM #{quoted} LIMIT 3")
    rescue StandardError
      []
    end

    def time_column?(col)
      col[:name].match?(/(_at|_on|date|time)\z/i) ||
        col[:name].match?(/\A(start|created|updated|completed)\z/i) ||
        col[:type].to_s.match?(/DATE|TIME|TIMESTAMP/i)
    end

    def profile_categoricals(quoted_table, columns, row_count)
      return {} if row_count > 50_000

      names = columns.map { |col| col[:name] }.select { |name| name.match?(/status|source|region|type|kind|outcome|state/i) }
      names.each_with_object({}) do |name, acc|
        quoted_col = db.quote_ident(name)
        values = db.execute("SELECT DISTINCT #{quoted_col} FROM #{quoted_table} LIMIT 12").flatten
        acc[name] = values
      rescue StandardError
        acc[name] = []
      end
    end
  end
end
