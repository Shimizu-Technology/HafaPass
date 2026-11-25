# frozen_string_literal: true

# Never-fulfilled classification foundation (docs/design/never-fulfilled-captures.md §4.1).
# Additive and inert for the running release: it never writes these columns.
class AddFulfillmentOwnershipColumns < ActiveRecord::Migration[8.1]
  def change
    # Derived by the database from the order's first order-scope classification.
    add_column :orders, :never_fulfilled_at, :datetime
    # The verified payment that fulfilled the order; set once at completion.
    add_column :orders, :fulfilled_by_payment_id, :bigint
    # Database-stamped time the capture was first recorded. succeeded_at stays
    # the legacy business field and can be backdated by the legacy backfill.
    add_column :payments, :capture_recorded_at, :datetime

    add_check_constraint :orders,
      "never_fulfilled_at IS NULL OR (completed_at IS NULL AND status NOT IN (0, 1))",
      name: "orders_never_fulfilled_not_completed", validate: false
    add_check_constraint :orders,
      "never_fulfilled_at IS NULL OR fulfilled_by_payment_id IS NULL",
      name: "orders_fulfilled_xor_never_fulfilled", validate: false
  end
end
