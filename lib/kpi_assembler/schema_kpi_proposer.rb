# frozen_string_literal: true

module KPIAssembler
  # Builds candidate KPI recipes from whatever tables were introspected.
  # Recognized schema patterns are overlays on top of generic volume, rate,
  # and revenue guesses.
  class SchemaKpiProposer
    SUCCESS_STATUSES = /converted|won|sold|closed|paid|complete|active|member/i.freeze
    MONEY = /amount|price|total|revenue|fee|mrr|sales_amount/i.freeze
    LOCATION = %w[location_id company_id site_id club_id].freeze

    def initialize(schema, options = {})
      @schema = schema
      @options = options
    end

    def propose
      candidates = []
      candidates.concat(sample_funnel_candidates) if sample_funnel_schema?
      candidates.concat(people_activity_candidates) if people_activity_schema?
      candidates.concat(generic_candidates)
      candidates.uniq { |kpi| kpi[:id] }.first(14)
    end

    private

    def sample_funnel_schema?
      %w[leads appointments memberships invoices locations].all? { |table| @schema.key?(table) }
    end

    def people_activity_schema?
      table_has?("people", %w[created_at]) && table_has?("activities", %w[start])
    end

    def sample_funnel_candidates
      [
        kpi(
          id: "lead_conversion_rate",
          name: "Lead to Member Conversion Rate",
          category: "Sales Funnel",
          owner: "sales",
          english: "Share of leads created in the period that converted to a membership.",
          sql: period_sql("leads", "created_at", "(CAST(COUNT(CASE WHEN status = 'converted' THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0)) * 100"),
          grain: "daily",
          location_column: "location_id",
          fact_table: "leads"
        ),
        kpi(
          id: "tour_show_rate",
          name: "Tour Show Rate",
          category: "Sales Funnel",
          owner: "sales",
          english: "Share of scheduled tours that were completed (shown), excluding cancellations from the denominator.",
          sql: period_sql("appointments", "scheduled_at", "(CAST(COUNT(CASE WHEN status = 'completed' THEN 1 END) AS FLOAT) / NULLIF(COUNT(CASE WHEN status IN ('completed', 'no_show') THEN 1 END), 0)) * 100"),
          grain: "daily",
          location_column: "location_id",
          fact_table: "appointments"
        ),
        kpi(
          id: "no_show_rate",
          name: "Tour No-Show Rate",
          category: "Sales Funnel",
          owner: "site_manager",
          english: "Share of scheduled tours marked no_show among completed + no_show visits.",
          sql: period_sql("appointments", "scheduled_at", "(CAST(COUNT(CASE WHEN status = 'no_show' THEN 1 END) AS FLOAT) / NULLIF(COUNT(CASE WHEN status IN ('completed', 'no_show') THEN 1 END), 0)) * 100"),
          grain: "daily",
          location_column: "location_id",
          fact_table: "appointments"
        ),
        kpi(
          id: "paid_mrr",
          name: "Paid Monthly Recurring Revenue",
          category: "Revenue",
          owner: "exec",
          english: "Sum of paid invoice amounts billed in the period.",
          sql: period_sql("invoices", "billed_at", "COALESCE(SUM(amount), 0)", extra: "status = 'paid'"),
          grain: "monthly",
          location_column: "location_id",
          fact_table: "invoices"
        ),
        kpi(
          id: "avg_revenue_per_member",
          name: "Average Revenue Per Member",
          category: "Revenue",
          owner: "exec",
          english: "Paid invoice amount divided by distinct memberships billed in the period.",
          sql: period_sql("invoices", "billed_at", "SUM(amount) / NULLIF(COUNT(DISTINCT membership_id), 0)", extra: "status = 'paid'"),
          grain: "monthly",
          location_column: "location_id",
          fact_table: "invoices"
        ),
        kpi(
          id: "active_memberships",
          name: "Active Memberships",
          category: "Retention",
          owner: "exec",
          english: "Memberships that started before period end and were not cancelled before period start.",
          sql: "SELECT COUNT(*) AS metric_value FROM memberships WHERE started_at < ? AND (cancelled_at IS NULL OR cancelled_at >= ?)#{tenant_and("memberships")}",
          grain: "daily",
          location_column: location_column_for("memberships"),
          fact_table: "memberships",
          bind_style: "end_then_start"
        ),
        kpi(
          id: "revenue_per_lead_unsafe",
          name: "Revenue per Lead (unconstrained join)",
          category: "Revenue",
          owner: "finance",
          english: "Invoice revenue divided by leads using an unconstrained join — expected to fail certification.",
          sql: "SELECT SUM(invoices.amount) / COUNT(leads.id) AS metric_value FROM leads JOIN invoices WHERE leads.created_at >= ? AND leads.created_at < ?",
          grain: "monthly",
          location_column: "leads.location_id",
          fact_table: "leads"
        )
      ]
    end

    def people_activity_candidates
      out = []
      people_loc = location_column_for("people")
      activity_loc = location_column_for("activities")

      out << kpi(
        id: "new_leads",
        name: "New leads",
        category: "Sales Funnel",
        owner: "sales",
        english: "People records created in the period.",
        sql: period_sql("people", "created_at", "COUNT(*)", extra: soft_delete("people")),
        grain: "daily",
        location_column: people_loc,
        fact_table: "people"
      )

      if column?("people", "sale_at")
        out << kpi(
          id: "lead_close_rate",
          name: "Lead close rate",
          category: "Sales Funnel",
          owner: "sales",
          english: "Share of people created in the period that have a sale_at timestamp.",
          sql: period_sql(
            "people",
            "created_at",
            "(CAST(COUNT(CASE WHEN sale_at IS NOT NULL THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0)) * 100",
            extra: soft_delete("people")
          ),
          grain: "daily",
          location_column: people_loc,
          fact_table: "people"
        )
      end

      extra = [soft_delete("activities"), "type = 'Event'"].compact.reject(&:empty?).join(" AND ")
      extra = nil if extra.empty?
      out << kpi(
        id: "scheduled_appointments",
        name: "Scheduled appointments",
        category: "Sales Funnel",
        owner: "sales",
        english: "Sales appointments (activities.type = Event) starting in the period.",
        sql: period_sql("activities", "start", "COUNT(*)", extra: extra),
        grain: "daily",
        location_column: activity_loc,
        fact_table: "activities"
      )

      if column?("activities", "complete")
        out << kpi(
          id: "appointment_completion_rate",
          name: "Appointment completion rate",
          category: "Sales Funnel",
          owner: "site_manager",
          english: "Share of period appointments marked complete.",
          sql: period_sql(
            "activities",
            "start",
            "(CAST(COUNT(CASE WHEN complete THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0)) * 100",
            extra: extra
          ),
          grain: "daily",
          location_column: activity_loc,
          fact_table: "activities"
        )
      end

      if column?("activities", "sales_amount")
        out << kpi(
          id: "appointment_sales_amount",
          name: "Appointment sales amount",
          category: "Revenue",
          owner: "exec",
          english: "Sum of sales_amount on appointments starting in the period.",
          sql: period_sql("activities", "start", "COALESCE(SUM(sales_amount), 0)", extra: extra),
          grain: "monthly",
          location_column: activity_loc,
          fact_table: "activities"
        )
      end

      out
    end

    def generic_candidates
      @schema.filter_map do |table, meta|
        next if sample_funnel_schema? && %w[leads appointments memberships invoices locations].include?(table)
        next if people_activity_schema? && %w[people activities companies].include?(table)

        time = pick_time(meta)
        next unless time

        money = meta[:columns].map { |col| col[:name] }.find { |name| name.match?(MONEY) }
        status_col = meta[:columns].map { |col| col[:name] }.find { |name| name.match?(/\A(status|state|outcome)\z/i) }
        loc = location_column_for(table)
        success = success_value(meta, status_col)

        if money
          extra = status_col && (meta.dig(:categorical_values, status_col) || []).any? { |value| value.to_s.match?(/paid/i) } ? "#{status_col} = 'paid'" : nil
          kpi(
            id: "#{table}_#{money}_sum",
            name: "#{human(table)} #{human(money)}",
            category: "Revenue",
            owner: "exec",
            english: "Sum of #{money} on #{table} in the period.",
            sql: period_sql(table, time, "COALESCE(SUM(#{money}), 0)", extra: extra),
            grain: "monthly",
            location_column: loc,
            fact_table: table
          )
        elsif success && status_col
          kpi(
            id: "#{table}_#{success}_rate",
            name: "#{human(table)} #{human(success)} rate",
            category: "Conversion",
            owner: "ops",
            english: "Share of #{table} rows whose #{status_col} is #{success}.",
            sql: period_sql(
              table,
              time,
              "(CAST(COUNT(CASE WHEN #{status_col} = '#{success}' THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0)) * 100"
            ),
            grain: "daily",
            location_column: loc,
            fact_table: table
          )
        else
          kpi(
            id: "#{table}_volume",
            name: "#{human(table)} volume",
            category: "Operations",
            owner: "ops",
            english: "Row count of #{table} in the period.",
            sql: period_sql(table, time, "COUNT(*)", extra: soft_delete(table)),
            grain: "daily",
            location_column: loc,
            fact_table: table
          )
        end
      end
    end

    def pick_time(meta)
      preferred = %w[created_at billed_at scheduled_at started_at occurred_at start completed_at]
      (preferred & meta[:time_columns]) .first || meta[:time_columns].first
    end

    def success_value(meta, status_col)
      return unless status_col

      Array(meta.dig(:categorical_values, status_col)).map(&:to_s).find { |value| value.match?(SUCCESS_STATUSES) }
    end

    def location_column_for(table)
      names = Array(@schema.dig(table, :columns)).map { |col| col[:name] }
      LOCATION.find { |column| names.include?(column) }
    end

    def table_has?(table, columns)
      return false unless @schema.key?(table)

      names = @schema[table][:columns].map { |col| col[:name] }
      columns.all? { |column| names.include?(column) }
    end

    def column?(table, name)
      Array(@schema.dig(table, :columns)).any? { |col| col[:name] == name }
    end

    def soft_delete(table)
      if column?(table, "deleted_at")
        "deleted_at IS NULL"
      elsif column?(table, "deleted")
        "deleted = false"
      end
    end

    def tenant_clause(table)
      column = @options[:tenant_column]
      id = @options[:tenant_id]
      return unless column && id && column?(table, column)

      "#{column} = #{Integer(id)}"
    end

    def tenant_and(table)
      clause = tenant_clause(table)
      clause ? " AND #{clause}" : ""
    end

    def period_sql(table, time_column, expression, extra: nil)
      clauses = ["#{time_column} >= ?", "#{time_column} < ?", extra, tenant_clause(table)].compact.reject { |part| part.to_s.empty? }
      "SELECT #{expression} AS metric_value FROM #{table} WHERE #{clauses.join(" AND ")}"
    end

    def human(value)
      value.to_s.tr("_", " ").gsub(/\b\w/, &:upcase)
    end

    def kpi(attrs)
      attrs.merge(formula_description: attrs.delete(:english) || attrs[:formula_description])
    end
  end
end
