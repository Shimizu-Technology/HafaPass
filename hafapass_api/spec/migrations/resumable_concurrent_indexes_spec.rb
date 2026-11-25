# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261124164200_index_online_door_checkout_sessions")
require Rails.root.join("db/migrate/20261124200200_index_re_entry_fields")
require Rails.root.join("db/migrate/20261126100100_index_fulfillment_ownership")

RSpec.describe "Resumable concurrent index migrations", :non_transactional do
  self.use_transactional_tests = false

  let(:conn) { ActiveRecord::Base.connection }

  def index_validity(name)
    conn.select_value(ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        SELECT i.indisvalid
        FROM pg_class c
        INNER JOIN pg_index i ON i.indexrelid = c.oid
        INNER JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema()
          AND c.relname = ?
          AND c.relkind = 'i'
        LIMIT 1
      SQL
      name
    ]))
  end

  def drop_index_if_present(name)
    conn.execute("DROP INDEX CONCURRENTLY IF EXISTS #{conn.quote_table_name(name)}")
  end

  def clean_test_data
    unless Rails.env.test? && conn.pool.db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    conn.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  after { clean_test_data }

  describe IndexReEntryFields do
    let(:index_names) do
      %w[
        index_tickets_on_event_id_and_occupancy_state
        index_tickets_on_last_entry_device_id
        index_admission_actions_on_event_day_occurred_at
      ]
    end

    after do
      ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
    end

    it "resumes cleanly when the first index already exists and is valid" do
      index_names.each { |name| drop_index_if_present(name) }
      conn.add_index(:tickets, [:event_id, :occupancy_state],
        name: "index_tickets_on_event_id_and_occupancy_state", algorithm: :concurrently)

      expect(index_validity("index_tickets_on_event_id_and_occupancy_state")).to be(true)
      expect(index_validity("index_tickets_on_last_entry_device_id")).to be_nil

      expect do
        ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
      end.not_to raise_error

      index_names.each do |name|
        expect(index_validity(name)).to be(true), "Expected #{name} to be valid"
      end
    end

    it "drops and rebuilds an invalid index left behind by an interrupted concurrent build" do
      index_names.each { |name| drop_index_if_present(name) }

      # Create two tickets sharing (event_id, occupancy_state) so CREATE UNIQUE INDEX CONCURRENTLY
      # fails mid-build and leaves a genuine PostgreSQL invalid index (indisvalid = false).
      event = create(:event)
      order = create(:order, event: event)
      tt = create(:ticket_type, event: event)
      t1 = create(:ticket, event: event, order: order, ticket_type: tt)
      t2 = create(:ticket, event: event, order: order, ticket_type: tt)
      begin
        expect do
          conn.execute(<<~SQL)
            CREATE UNIQUE INDEX CONCURRENTLY index_tickets_on_event_id_and_occupancy_state
            ON tickets (event_id, occupancy_state)
          SQL
        end.to raise_error(ActiveRecord::RecordNotUnique)
        expect(index_validity("index_tickets_on_event_id_and_occupancy_state")).to be(false)

        expect do
          ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
        end.not_to raise_error

        index_names.each do |name|
          expect(index_validity(name)).to be(true), "Expected #{name} to be rebuilt valid"
        end
      ensure
        t1.destroy!
        t2.destroy!
        tt.destroy!
        order.destroy!
        event.destroy!
      end
    end
  end

  describe IndexOnlineDoorCheckoutSessions do
    let(:index_name) { "index_payments_on_stripe_checkout_session_id" }

    after do
      ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
    end

    it "skips when the valid index already exists" do
      drop_index_if_present(index_name)
      conn.add_index(:payments, :stripe_checkout_session_id, name: index_name, unique: true,
        algorithm: :concurrently, where: "stripe_checkout_session_id IS NOT NULL")
      expect(index_validity(index_name)).to be(true)

      expect do
        ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
      end.not_to raise_error

      expect(index_validity(index_name)).to be(true)
    end

    it "drops and rebuilds an invalid index left behind by an interrupted concurrent build" do
      drop_index_if_present(index_name)
      event = create(:event)
      order = create(:order, event: event)
      p1 = create(:payment, order: order, stripe_checkout_session_id: "cs_test_dup_invalid")
      p2 = create(:payment, order: order, stripe_checkout_session_id: "cs_test_dup_invalid")
      begin
        expect do
          conn.execute(<<~SQL)
            CREATE UNIQUE INDEX CONCURRENTLY #{index_name}
            ON payments (stripe_checkout_session_id)
            WHERE stripe_checkout_session_id IS NOT NULL
          SQL
        end.to raise_error(ActiveRecord::RecordNotUnique)
        expect(index_validity(index_name)).to be(false)

        p2.update!(stripe_checkout_session_id: "cs_test_unique_fixed")

        expect do
          ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
        end.not_to raise_error

        expect(index_validity(index_name)).to be(true)
      ensure
        p1.destroy!
        p2.destroy!
        order.destroy!
        event.destroy!
      end
    end
  end

  describe IndexFulfillmentOwnership do
    # index_payments_on_id_and_order_id backs two composite foreign keys, so it
    # cannot be dropped here; the migration must skip it while valid.
    let(:index_name) { "index_orders_on_fulfilled_by_payment_id" }

    after do
      ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
    end

    it "skips the valid payment identity index and rebuilds an invalid fulfilling-payment index" do
      drop_index_if_present(index_name)
      event = create(:event)
      first = create(:order, event: event)
      second = create(:order, event: event)
      begin
        # Interrupted build: a same-named unique index on a duplicated column fails and stays invalid.
        expect do
          conn.execute("CREATE UNIQUE INDEX CONCURRENTLY #{index_name} ON orders (event_id)")
        end.to raise_error(ActiveRecord::RecordNotUnique)
        expect(index_validity(index_name)).to be(false)
        expect(index_validity("index_payments_on_id_and_order_id")).to be(true)

        expect do
          ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
        end.not_to raise_error

        expect(index_validity(index_name)).to be(true)
        definition = conn.select_value("SELECT pg_get_indexdef('#{index_name}'::regclass)")
        expect(definition).to include("(fulfilled_by_payment_id)", "WHERE (fulfilled_by_payment_id IS NOT NULL)")
        expect(definition).not_to include("UNIQUE")
      ensure
        second.destroy!
        first.destroy!
        event.destroy!
      end
    end
  end
end
