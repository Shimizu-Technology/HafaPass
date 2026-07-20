# frozen_string_literal: true

class CreateCommerceLedger < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :currency, :string, null: false, default: "usd"
    add_column :orders, :expires_at, :datetime
    add_column :orders, :cancelled_at, :datetime
    add_column :orders, :expired_at, :datetime
    add_index :orders, :stripe_payment_intent_id, unique: true,
      where: "stripe_payment_intent_id IS NOT NULL",
      name: "index_orders_on_unique_payment_intent"
    add_check_constraint :orders, "subtotal_cents >= 0", name: "orders_subtotal_nonnegative"
    add_check_constraint :orders, "service_fee_cents >= 0", name: "orders_service_fee_nonnegative"
    add_check_constraint :orders, "discount_cents >= 0", name: "orders_discount_nonnegative"
    add_check_constraint :orders, "total_cents >= 0", name: "orders_total_nonnegative"
    add_check_constraint :orders, "refund_amount_cents >= 0", name: "orders_refund_nonnegative"
    add_check_constraint :orders, "char_length(currency) = 3", name: "orders_currency_length"
    add_check_constraint :orders, "status IN (0, 1, 2, 3, 4, 5)", name: "orders_status_valid"

    add_check_constraint :ticket_types, "price_cents >= 0", name: "ticket_types_price_nonnegative"
    add_check_constraint :ticket_types, "quantity_available > 0", name: "ticket_types_quantity_positive"
    add_check_constraint :ticket_types, "quantity_sold >= 0", name: "ticket_types_sold_nonnegative"
    add_check_constraint :ticket_types, "max_per_order IS NULL OR max_per_order > 0",
      name: "ticket_types_max_per_order_positive"
    add_check_constraint :events, "max_capacity IS NULL OR max_capacity > 0", name: "events_capacity_positive"
    add_check_constraint :promo_codes, "current_uses >= 0", name: "promo_codes_uses_nonnegative"
    add_check_constraint :promo_codes, "max_uses IS NULL OR max_uses > 0", name: "promo_codes_max_uses_positive"

    remove_index :organizer_profiles, :user_id if index_exists?(:organizer_profiles, :user_id)
    add_index :organizer_profiles, :user_id, unique: true

    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket_type, null: true, foreign_key: { on_delete: :restrict }
      t.references :pricing_tier, null: true, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      t.string :tier_name
      t.integer :unit_price_cents, null: false
      t.integer :quantity, null: false
      t.integer :subtotal_cents, null: false
      t.integer :discount_cents, null: false, default: 0
      t.integer :fee_cents, null: false, default: 0
      t.integer :tax_cents, null: false, default: 0
      t.integer :organizer_proceeds_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.timestamps
    end
    add_check_constraint :order_items, "quantity > 0", name: "order_items_quantity_positive"
    add_check_constraint :order_items, "unit_price_cents >= 0", name: "order_items_unit_price_nonnegative"
    add_check_constraint :order_items, "subtotal_cents >= 0", name: "order_items_subtotal_nonnegative"
    add_check_constraint :order_items, "discount_cents >= 0", name: "order_items_discount_nonnegative"
    add_check_constraint :order_items, "fee_cents >= 0", name: "order_items_fee_nonnegative"
    add_check_constraint :order_items, "tax_cents >= 0", name: "order_items_tax_nonnegative"
    add_check_constraint :order_items, "organizer_proceeds_cents >= 0", name: "order_items_proceeds_nonnegative"
    add_check_constraint :order_items, "char_length(currency) = 3", name: "order_items_currency_length"

    create_table :fee_components do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_item, null: true, foreign_key: { on_delete: :restrict }
      t.string :kind, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.boolean :estimated, null: false, default: true
      t.string :provider_reference
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :fee_components, "amount_cents >= 0", name: "fee_components_amount_nonnegative"
    add_check_constraint :fee_components, "char_length(currency) = 3", name: "fee_components_currency_length"

    create_table :inventory_holds do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket_type, null: false, foreign_key: { on_delete: :restrict }
      t.references :pricing_tier, null: true, foreign_key: { on_delete: :restrict }
      t.integer :quantity, null: false
      t.integer :status, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end
    add_index :inventory_holds, [:status, :expires_at]
    add_check_constraint :inventory_holds, "quantity > 0", name: "inventory_holds_quantity_positive"
    add_check_constraint :inventory_holds, "status IN (0, 1, 2, 3)", name: "inventory_holds_status_valid"

    create_table :payments do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.string :provider, null: false, default: "stripe"
      t.string :provider_payment_id
      t.string :idempotency_key, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :failure_code
      t.text :failure_message
      t.datetime :succeeded_at
      t.datetime :failed_at
      t.jsonb :provider_payload, null: false, default: {}
      t.timestamps
    end
    add_index :payments, :idempotency_key, unique: true
    add_index :payments, [:provider, :provider_payment_id], unique: true,
      where: "provider_payment_id IS NOT NULL",
      name: "index_payments_on_unique_provider_payment"
    add_check_constraint :payments, "amount_cents >= 0", name: "payments_amount_nonnegative"
    add_check_constraint :payments, "char_length(currency) = 3", name: "payments_currency_length"
    add_check_constraint :payments, "status IN (0, 1, 2, 3, 4, 5)", name: "payments_status_valid"

    create_table :webhook_events do |t|
      t.string :provider, null: false, default: "stripe"
      t.string :provider_event_id, null: false
      t.string :event_type, null: false
      t.integer :status, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.text :last_error
      t.datetime :provider_created_at
      t.datetime :processed_at
      t.timestamps
    end
    add_index :webhook_events, [:provider, :provider_event_id], unique: true,
      name: "index_webhook_events_on_unique_provider_event"
    add_index :webhook_events, [:status, :created_at]
    add_check_constraint :webhook_events, "status IN (0, 1, 2, 3, 4)", name: "webhook_events_status_valid"
    add_check_constraint :webhook_events, "attempts >= 0", name: "webhook_events_attempts_nonnegative"

    create_table :payment_events do |t|
      t.references :payment, null: true, foreign_key: { on_delete: :restrict }
      t.references :webhook_event, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.string :event_type, null: false
      t.integer :amount_cents
      t.string :currency
      t.datetime :provider_created_at
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :payment_events, "amount_cents IS NULL OR amount_cents >= 0",
      name: "payment_events_amount_nonnegative"
    add_check_constraint :payment_events, "currency IS NULL OR char_length(currency) = 3",
      name: "payment_events_currency_length"

    create_table :refunds do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :payment, null: true, foreign_key: { on_delete: :restrict }
      t.references :requested_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :provider, null: false, default: "stripe"
      t.string :provider_refund_id
      t.string :idempotency_key, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :reason
      t.string :failure_code
      t.text :failure_message
      t.datetime :succeeded_at
      t.datetime :failed_at
      t.jsonb :provider_payload, null: false, default: {}
      t.timestamps
    end
    add_index :refunds, :idempotency_key, unique: true
    add_index :refunds, [:provider, :provider_refund_id], unique: true,
      where: "provider_refund_id IS NOT NULL",
      name: "index_refunds_on_unique_provider_refund"
    add_check_constraint :refunds, "amount_cents > 0", name: "refunds_amount_positive"
    add_check_constraint :refunds, "char_length(currency) = 3", name: "refunds_currency_length"
    add_check_constraint :refunds, "status IN (0, 1, 2, 3)", name: "refunds_status_valid"

    create_table :refund_items do |t|
      t.references :refund, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_item, null: false, foreign_key: { on_delete: :restrict }
      t.integer :amount_cents, null: false
      t.integer :quantity, null: false, default: 0
      t.timestamps
    end
    add_index :refund_items, [:refund_id, :order_item_id], unique: true
    add_check_constraint :refund_items, "amount_cents >= 0", name: "refund_items_amount_nonnegative"
    add_check_constraint :refund_items, "quantity >= 0", name: "refund_items_quantity_nonnegative"

    create_table :promo_redemptions do |t|
      t.references :promo_code, null: false, foreign_key: { on_delete: :restrict }
      t.references :order, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.integer :discount_cents, null: false
      t.datetime :expires_at
      t.datetime :finalized_at
      t.datetime :released_at
      t.timestamps
    end
    add_index :promo_redemptions, [:promo_code_id, :status]
    add_check_constraint :promo_redemptions, "discount_cents >= 0", name: "promo_redemptions_discount_nonnegative"
    add_check_constraint :promo_redemptions, "status IN (0, 1, 2)", name: "promo_redemptions_status_valid"

    create_table :reconciliation_exceptions do |t|
      t.references :order, null: true, foreign_key: { on_delete: :restrict }
      t.references :payment, null: true, foreign_key: { on_delete: :restrict }
      t.references :webhook_event, null: true, foreign_key: { on_delete: :restrict }
      t.string :code, null: false
      t.integer :status, null: false, default: 0
      t.integer :expected_amount_cents
      t.integer :actual_amount_cents
      t.string :expected_currency
      t.string :actual_currency
      t.jsonb :details, null: false, default: {}
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :reconciliation_exceptions, [:status, :created_at]
    add_check_constraint :reconciliation_exceptions, "status IN (0, 1)",
      name: "reconciliation_exceptions_status_valid"

    add_reference :tickets, :order_item, null: true, foreign_key: { on_delete: :restrict }
  end
end
