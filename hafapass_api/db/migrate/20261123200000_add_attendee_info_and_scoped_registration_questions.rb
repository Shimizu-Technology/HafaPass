# frozen_string_literal: true

# Per-ticket attendee details and registration questions scoped to ticket
# types. Order-scoped answers stay unique per order; ticket-scoped answers are
# unique per ticket. Checkout stores collected attendee details on the order
# item so asynchronous (webhook) payment completion can write them onto each
# issued ticket.
class AddAttendeeInfoAndScopedRegistrationQuestions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Re-runnable: a failed concurrent index build leaves the earlier steps in
  # place, so each step is skipped when already applied and an INVALID index
  # is rebuilt.
  def up
    add_column :ticket_types, :attendee_info_mode, :string, default: "none", null: false, if_not_exists: true
    unless check_constraint_exists?(:ticket_types, name: "ticket_types_attendee_info_mode_valid")
      add_check_constraint :ticket_types, "attendee_info_mode IN ('none', 'name_only', 'name_and_email')",
        name: "ticket_types_attendee_info_mode_valid", validate: false
    end
    validate_check_constraint :ticket_types, name: "ticket_types_attendee_info_mode_valid"

    add_column :registration_questions, :scope, :integer, default: 0, null: false, if_not_exists: true
    add_column :registration_questions, :ticket_type_ids, :jsonb, default: [], null: false, if_not_exists: true
    add_column :registration_questions, :show_on_scanner, :boolean, default: false, null: false, if_not_exists: true
    add_column :registration_questions, :help_text, :string, limit: 250, if_not_exists: true
    add_column :registration_questions, :validation_rules, :jsonb, default: {}, null: false, if_not_exists: true
    remove_check_constraint :registration_questions, name: "registration_questions_kind_valid", if_exists: true
    add_check_constraint :registration_questions, "kind = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7])",
      name: "registration_questions_kind_valid", validate: false
    validate_check_constraint :registration_questions, name: "registration_questions_kind_valid"
    {
      "registration_questions_scope_valid" => "scope = ANY (ARRAY[0, 1])",
      "registration_questions_ticket_type_ids_array" => "jsonb_typeof(ticket_type_ids) = 'array'",
      "registration_questions_validation_rules_object" => "jsonb_typeof(validation_rules) = 'object'"
    }.each do |name, expression|
      unless check_constraint_exists?(:registration_questions, name: name)
        add_check_constraint :registration_questions, expression, name: name, validate: false
      end
      validate_check_constraint :registration_questions, name: name
    end

    add_column :order_items, :metadata, :jsonb, default: {}, null: false, if_not_exists: true

    add_column :registration_responses, :ticket_id, :bigint, if_not_exists: true
    drop_invalid_index(:registration_responses, "index_registration_responses_on_ticket_id")
    add_index :registration_responses, :ticket_id, algorithm: :concurrently, if_not_exists: true
    unless foreign_key_exists?(:registration_responses, :tickets)
      add_foreign_key :registration_responses, :tickets, on_delete: :restrict, validate: false
    end
    validate_foreign_key :registration_responses, :tickets
    drop_invalid_index(:registration_responses, "index_registration_responses_unique_order")
    add_index :registration_responses, [:order_id, :registration_question_id],
      unique: true, where: "ticket_id IS NULL",
      name: "index_registration_responses_unique_order", algorithm: :concurrently, if_not_exists: true
    drop_invalid_index(:registration_responses, "index_registration_responses_unique_ticket")
    add_index :registration_responses, [:ticket_id, :registration_question_id],
      unique: true, where: "ticket_id IS NOT NULL",
      name: "index_registration_responses_unique_ticket", algorithm: :concurrently, if_not_exists: true
    remove_index :registration_responses, name: "index_registration_responses_unique",
      algorithm: :concurrently, if_exists: true
  end

  # Rolling back is allowed only while nothing depends on the new shape:
  # no per-ticket answers (the order-wide unique index would reject them), no
  # question using a new kind, per-ticket scope or ticket type limit (the old
  # schema would ask it in every cart), and no pending order holding attendee
  # details that tickets still need. Every check runs before any change, so a
  # refused rollback leaves the schema untouched. Settings such as
  # attendee_info_mode, help_text and show_on_scanner are dropped.
  def down
    blocker = rollback_blocker
    raise ActiveRecord::IrreversibleMigration, blocker if blocker

    drop_invalid_index(:registration_responses, "index_registration_responses_unique")
    add_index :registration_responses, [:order_id, :registration_question_id],
      unique: true, name: "index_registration_responses_unique", algorithm: :concurrently, if_not_exists: true
    remove_index :registration_responses, name: "index_registration_responses_unique_ticket",
      algorithm: :concurrently, if_exists: true
    remove_index :registration_responses, name: "index_registration_responses_unique_order",
      algorithm: :concurrently, if_exists: true
    remove_foreign_key :registration_responses, :tickets
    remove_index :registration_responses, :ticket_id, algorithm: :concurrently, if_exists: true
    remove_column :registration_responses, :ticket_id

    remove_column :order_items, :metadata

    remove_check_constraint :registration_questions, name: "registration_questions_validation_rules_object"
    remove_check_constraint :registration_questions, name: "registration_questions_ticket_type_ids_array"
    remove_check_constraint :registration_questions, name: "registration_questions_scope_valid"
    remove_check_constraint :registration_questions, name: "registration_questions_kind_valid"
    add_check_constraint :registration_questions, "kind = ANY (ARRAY[0, 1, 2, 3])",
      name: "registration_questions_kind_valid"
    remove_column :registration_questions, :validation_rules
    remove_column :registration_questions, :help_text
    remove_column :registration_questions, :show_on_scanner
    remove_column :registration_questions, :ticket_type_ids
    remove_column :registration_questions, :scope

    remove_check_constraint :ticket_types, name: "ticket_types_attendee_info_mode_valid"
    remove_column :ticket_types, :attendee_info_mode
  end

  private

  def rollback_blocker
    if select_value("SELECT 1 FROM registration_responses WHERE ticket_id IS NOT NULL LIMIT 1")
      return "Per-ticket registration answers exist; the order-wide unique index cannot hold them"
    end
    if select_value("SELECT 1 FROM registration_questions WHERE kind > 3 OR scope <> 0 LIMIT 1")
      return "Registration questions use a new answer type or per-ticket scope; change them back first"
    end
    if select_value("SELECT 1 FROM registration_questions WHERE ticket_type_ids <> '[]'::jsonb LIMIT 1")
      return "Registration questions are limited to specific ticket types; rolling back would ask them in every cart"
    end
    if select_value(<<~SQL.squish)
      SELECT 1 FROM order_items INNER JOIN orders ON orders.id = order_items.order_id
      WHERE orders.status = 0 AND order_items.metadata ? 'attendees' LIMIT 1
    SQL
      "Pending orders hold attendee details that their tickets still need"
    end
  end

  # A canceled concurrent build leaves an INVALID index that if_not_exists
  # would keep; rebuild it instead.
  def drop_invalid_index(table, name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index INNER JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname = #{connection.quote(name)} AND NOT pg_index.indisvalid
    SQL
    remove_index table, name: name, algorithm: :concurrently if invalid
  end
end
