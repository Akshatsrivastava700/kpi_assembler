# frozen_string_literal: true

require_relative "connection"

module KPIAssembler
  class LocationDirectory
    def initialize(db, tenant_id: nil)
      @db = Connection.wrap(db)
      @tenant_id = tenant_id
    end

    def all
      if @tenant_id
        scoped = fetch("SELECT id, name FROM companies WHERE id = ? LIMIT 1", [Integer(@tenant_id)])
        return scoped unless scoped.empty?
      end

      named = fetch("SELECT id, name FROM locations ORDER BY id LIMIT 12")
      return named unless named.empty?

      fetch("SELECT id, name FROM companies ORDER BY id LIMIT 12")
    end

    private

    def fetch(sql, binds = [])
      @db.execute(sql, binds).map { |id, name| { id: id.to_i, name: name.to_s } }
    rescue StandardError
      []
    end
  end
end
