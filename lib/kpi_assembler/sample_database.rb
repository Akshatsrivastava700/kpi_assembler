# frozen_string_literal: true

require "sqlite3"
require "time"

module KPIAssembler
  # In-memory CRM funnel used for local demonstrations and tests.
  # Grain: lead → appointment (tour) → membership → invoice, with a location dimension.
  class SampleDatabase
    LOCATIONS = [
      { id: 1, name: "Downtown", region: "West" },
      { id: 2, name: "Riverside", region: "East" },
      { id: 3, name: "Hillside", region: "West" }
    ].freeze

    SOURCES = %w[walk_in web referral paid_ads].freeze
    LEAD_STATUSES = %w[open touring converted lost].freeze

    def self.build(seed: 2026)
      new(seed: seed).build
    end

    def initialize(seed: 2026)
      @rng = Random.new(seed)
      @now = Time.now.utc
    end

    def build
      db = SQLite3::Database.new(":memory:")
      db.execute("PRAGMA foreign_keys = ON;")
      create_schema(db)
      seed(db)
      db
    end

    private

    def create_schema(db)
      db.execute_batch(<<~SQL)
        CREATE TABLE locations (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          region TEXT NOT NULL
        );

        CREATE TABLE leads (
          id INTEGER PRIMARY KEY,
          location_id INTEGER NOT NULL REFERENCES locations(id),
          name TEXT NOT NULL,
          source TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          converted_at TEXT
        );

        CREATE TABLE appointments (
          id INTEGER PRIMARY KEY,
          lead_id INTEGER NOT NULL REFERENCES leads(id),
          location_id INTEGER NOT NULL REFERENCES locations(id),
          scheduled_at TEXT NOT NULL,
          status TEXT NOT NULL
        );

        CREATE TABLE memberships (
          id INTEGER PRIMARY KEY,
          lead_id INTEGER NOT NULL REFERENCES leads(id),
          location_id INTEGER NOT NULL REFERENCES locations(id),
          started_at TEXT NOT NULL,
          cancelled_at TEXT,
          monthly_fee REAL NOT NULL
        );

        CREATE TABLE invoices (
          id INTEGER PRIMARY KEY,
          membership_id INTEGER NOT NULL REFERENCES memberships(id),
          location_id INTEGER NOT NULL REFERENCES locations(id),
          amount REAL NOT NULL,
          status TEXT NOT NULL,
          billed_at TEXT NOT NULL
        );
      SQL
    end

    def seed(db)
      LOCATIONS.each do |loc|
        db.execute(
          "INSERT INTO locations (id, name, region) VALUES (?, ?, ?)",
          [loc[:id], loc[:name], loc[:region]]
        )
      end

      lead_id = 0
      appt_id = 0
      membership_id = 0
      invoice_id = 0

      180.times do |i|
        lead_id += 1
        location_id = 1 + (i % 3)
        created = days_ago(90 - (i % 90))
        source = SOURCES[i % SOURCES.length]
        roll = @rng.rand

        # Riverside (2) has a higher no-show / lower convert rate so briefings have a story.
        convert_cut = location_id == 2 ? 0.28 : 0.42
        tour_cut = location_id == 2 ? 0.55 : 0.70

        status =
          if roll < convert_cut
            "converted"
          elsif roll < tour_cut
            "touring"
          elsif roll < 0.88
            "lost"
          else
            "open"
          end

        converted_at = status == "converted" ? (created + (3 + @rng.rand(14)) * 86_400) : nil
        converted_at = [@now, converted_at].compact.min if converted_at

        db.execute(
          "INSERT INTO leads (id, location_id, name, source, status, created_at, converted_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)",
          [lead_id, location_id, "Lead #{lead_id}", source, status, iso(created), converted_at && iso(converted_at)]
        )

        next unless %w[touring converted lost].include?(status)

        appt_id += 1
        scheduled = created + (1 + @rng.rand(10)) * 86_400
        scheduled = [@now, scheduled].min
        appt_status =
          if status == "converted"
            "completed"
          elsif location_id == 2 && @rng.rand < 0.45
            "no_show"
          elsif @rng.rand < 0.18
            "no_show"
          elsif @rng.rand < 0.08
            "cancelled"
          else
            "completed"
          end

        db.execute(
          "INSERT INTO appointments (id, lead_id, location_id, scheduled_at, status)
           VALUES (?, ?, ?, ?, ?)",
          [appt_id, lead_id, location_id, iso(scheduled), appt_status]
        )

        next unless status == "converted"

        membership_id += 1
        started = converted_at
        fee = [39.0, 49.0, 59.0, 79.0][i % 4]
        cancelled_at = nil
        if @rng.rand < 0.12 && started < days_ago(20)
          cancelled_at = started + (20 + @rng.rand(40)) * 86_400
          cancelled_at = [@now, cancelled_at].min
        end

        db.execute(
          "INSERT INTO memberships (id, lead_id, location_id, started_at, cancelled_at, monthly_fee)
           VALUES (?, ?, ?, ?, ?, ?)",
          [membership_id, lead_id, location_id, iso(started), cancelled_at && iso(cancelled_at), fee]
        )

        bill = started
        while bill < @now && bill < (cancelled_at || @now)
          invoice_id += 1
          paid = bill < days_ago(2) || @rng.rand < 0.9
          db.execute(
            "INSERT INTO invoices (id, membership_id, location_id, amount, status, billed_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            [invoice_id, membership_id, location_id, fee, paid ? "paid" : "pending", iso(bill)]
          )
          bill += 30 * 86_400
        end
      end
    end

    def days_ago(n)
      @now - (n * 86_400)
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
