# frozen_string_literal: true

require "uri"

module KPIAssembler
  # Uniform query surface for SQLite and PostgreSQL. KPI SQL keeps `?`
  # placeholders; Postgres binds are rewritten to $1, $2, ...
  class Connection
    attr_reader :raw, :adapter, :label

    def self.wrap(object, label: nil)
      return object if object.is_a?(Connection)

      if object.respond_to?(:with_connection)
        adapter_name = object.with_connection { |connection| connection.adapter_name }
        adapter = adapter_name.to_s.match?(/postgre/i) ? :postgres : :sqlite
        new(raw: object, adapter: adapter, label: label || "ActiveRecord #{adapter_name}", pool: true)
      elsif defined?(SQLite3::Database) && object.is_a?(SQLite3::Database)
        new(raw: object, adapter: :sqlite, label: label || "sqlite")
      elsif defined?(PG::Connection) && object.is_a?(PG::Connection)
        new(raw: object, adapter: :postgres, label: label || "postgres")
      else
        raise Error, "Unsupported database object: #{object.class}"
      end
    end

    def self.open(url: nil, sqlite_path: nil)
      url ||= ENV["KPI_DATABASE_URL"]
      sqlite_path ||= ENV["KPI_DATABASE_PATH"]

      if url && !url.to_s.empty?
        from_url(url)
      elsif sqlite_path && !sqlite_path.to_s.empty?
        require "sqlite3"
        wrap(SQLite3::Database.new(sqlite_path), label: sqlite_path)
      else
        require_relative "sample_database"
        wrap(SampleDatabase.build, label: "Built-in sample database")
      end
    end

    def self.from_url(url)
      uri = URI.parse(url)
      case uri.scheme
      when "postgres", "postgresql"
        require "pg"
        dbname = uri.path.to_s.sub(%r{\A/}, "")
        raw = PG.connect(
          host: uri.host,
          port: uri.port || 5432,
          dbname: dbname,
          user: uri.user,
          password: uri.password
        )
        wrap(raw, label: "#{uri.host}/#{dbname}")
      when "sqlite", "sqlite3"
        require "sqlite3"
        path = uri.host == ":memory:" ? ":memory:" : uri.path
        wrap(SQLite3::Database.new(path), label: path)
      else
        raise Error, "Unsupported database URL scheme: #{uri.scheme.inspect}"
      end
    end

    def initialize(raw:, adapter:, label:, pool: false)
      @raw = raw
      @adapter = adapter.to_sym
      @label = label
      @pool = pool
    end

    def postgres?
      adapter == :postgres
    end

    def sqlite?
      adapter == :sqlite
    end

    def dialect
      postgres? ? "PostgreSQL" : "SQLite"
    end

    # Stable identity for caching. Host applications hand back a fresh connection
    # object on every request, so object identity cannot be used here.
    def cache_key
      [adapter, label, pool_name]
    end

    def execute(sql, binds = [])
      binds = Array(binds)
      return execute_with_pool(sql, binds) if @pool

      execute_raw(raw, sql, binds)
    end

    def explain(sql)
      if sqlite?
        execute("EXPLAIN QUERY PLAN #{sql}")
      else
        execute("EXPLAIN #{pg_sql(sql)}")
      end
    end

    def quote_ident(name)
      %("#{name.to_s.gsub('"', '""')}")
    end

    private

    def pool_name
      return nil unless @pool && raw.respond_to?(:db_config)

      raw.db_config.name
    end

    def execute_with_pool(sql, binds)
      raw.with_connection do |connection|
        execute_raw(connection.raw_connection, sql, binds)
      end
    end

    def execute_raw(connection, sql, binds)
      if sqlite?
        binds.empty? ? connection.execute(sql) : connection.execute(sql, binds)
      else
        result = binds.empty? ? connection.exec(sql) : connection.exec_params(pg_sql(sql), binds)
        result.values
      end
    end

    def pg_sql(sql)
      index = 0
      sql.gsub("?") do
        index += 1
        "$#{index}"
      end
    end
  end
end
