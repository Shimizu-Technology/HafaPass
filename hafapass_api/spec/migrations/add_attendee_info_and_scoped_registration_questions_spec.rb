# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261123200000_add_attendee_info_and_scoped_registration_questions")

RSpec.describe AddAttendeeInfoAndScopedRegistrationQuestions, :non_transactional do
  self.use_transactional_tests = false

  let(:migration) { described_class.new(described_class.name, 20_261_123_200_000) }
  let(:connection) { ActiveRecord::Base.connection }
  let(:models) { [TicketType, RegistrationQuestion, RegistrationResponse, OrderItem] }
  # Synthetic rows far above any factory ID, inserted without foreign keys so
  # only these two tables are touched.
  let(:base_id) { 990_000_000 }

  around do |example|
    raise "Migration specs must only run in test" unless Rails.env.test?

    verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
  ensure
    without_foreign_keys do
      connection.execute("DELETE FROM registration_responses WHERE id >= #{base_id}")
      connection.execute("DELETE FROM registration_questions WHERE id >= #{base_id}")
    end
    migration.migrate(:up) unless connection.column_exists?(:registration_responses, :ticket_id)
    models.each(&:reset_column_information)
    ActiveRecord::Migration.verbose = verbose
  end

  def without_foreign_keys
    connection.execute("SET session_replication_role = replica")
    yield
  ensure
    connection.execute("SET session_replication_role = DEFAULT")
  end

  def insert_question(kind: 0, scope: 0)
    without_foreign_keys do
      connection.execute(<<~SQL.squish)
        INSERT INTO registration_questions (id, event_id, prompt, kind, scope, created_at, updated_at)
        VALUES (#{base_id}, #{base_id}, 'Synthetic', #{kind}, #{scope}, now(), now())
      SQL
    end
  end

  def insert_response(ticket_id: nil)
    without_foreign_keys do
      connection.execute(<<~SQL.squish)
        INSERT INTO registration_responses (id, order_id, registration_question_id, ticket_id, prompt_snapshot,
          kind_snapshot, answered_at, created_at, updated_at)
        VALUES (#{base_id}, #{base_id}, #{base_id}, #{ticket_id || 'NULL'}, 'Synthetic', 0, now(), now(), now())
      SQL
    end
  end

  def valid_index?(name)
    connection.select_value(<<~SQL.squish)
      SELECT pg_index.indisvalid FROM pg_index INNER JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname = #{connection.quote(name)}
    SQL
  end

  it "refuses to roll back over per-ticket answers or new question kinds, leaving the schema untouched" do
    insert_question(kind: RegistrationQuestion.kinds.fetch("number"))
    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /new answer type/)

    connection.execute("UPDATE registration_questions SET kind = 0 WHERE id = #{base_id}")
    insert_response(ticket_id: base_id)
    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /Per-ticket registration answers/)

    expect(connection.column_exists?(:registration_responses, :ticket_id)).to be(true)
    expect(connection.column_exists?(:ticket_types, :attendee_info_mode)).to be(true)
    expect(valid_index?("index_registration_responses_unique_order")).to be(true)
    expect(valid_index?("index_registration_responses_unique_ticket")).to be(true)
    expect(valid_index?("index_registration_responses_unique")).to be_nil
  end

  it "rolls back and re-applies cleanly with order-wide answers present" do
    insert_question
    insert_response

    migration.migrate(:down)
    expect(connection.column_exists?(:registration_responses, :ticket_id)).to be(false)
    expect(connection.column_exists?(:order_items, :metadata)).to be(false)
    expect(valid_index?("index_registration_responses_unique")).to be(true)
    expect(connection.check_constraints(:registration_questions).find { |item| item.name == "registration_questions_kind_valid" }
      .expression).to include("0, 1, 2, 3]")

    migration.migrate(:up)
    expect(valid_index?("index_registration_responses_unique_order")).to be(true)
    expect(valid_index?("index_registration_responses_unique_ticket")).to be(true)
    expect(valid_index?("index_registration_responses_unique")).to be_nil
    expect(connection.select_value("SELECT COUNT(*) FROM registration_responses WHERE id = #{base_id}")).to eq(1)
  end
end
