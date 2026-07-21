# frozen_string_literal: true

class CreateCompetitiveGeneralAdmission < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :fee_policy, :integer, null: false, default: 0
    add_column :events, :buyer_fee_percent, :integer, null: false, default: 100
    add_column :events, :transfers_enabled, :boolean, null: false, default: true
    add_column :events, :supported_locales, :jsonb, null: false, default: ["en"]
    add_check_constraint :events, "fee_policy IN (0, 1, 2)", name: "events_fee_policy_valid"
    add_check_constraint :events, "buyer_fee_percent BETWEEN 0 AND 100", name: "events_buyer_fee_percent_valid"

    add_reference :tickets, :holder_user, foreign_key: { to_table: :users, on_delete: :restrict }
    add_column :tickets, :holder_email, :string
    add_index :tickets, "LOWER(holder_email)", name: "index_tickets_on_lower_holder_email"
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE tickets
          SET holder_user_id = orders.user_id,
              holder_email = LOWER(COALESCE(tickets.attendee_email, orders.buyer_email))
          FROM orders
          WHERE orders.id = tickets.order_id
        SQL
      end
    end

    create_table :ticket_transfers do |t|
      t.references :ticket, null: false, foreign_key: { on_delete: :restrict }
      t.references :initiated_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :accepted_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :recipient_email, null: false
      t.string :recipient_name
      t.integer :status, null: false, default: 0
      t.integer :token_version, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :cancelled_at
      t.timestamps
    end
    add_check_constraint :ticket_transfers, "status IN (0, 1, 2, 3, 4)", name: "ticket_transfers_status_valid"
    add_index :ticket_transfers, :ticket_id, unique: true, where: "status = 0",
      name: "index_ticket_transfers_one_pending"
    add_index :ticket_transfers, "LOWER(recipient_email)", name: "index_ticket_transfers_on_lower_recipient"

    add_column :waitlist_entries, :management_version, :integer, null: false, default: 0
    create_table :waitlist_offers do |t|
      t.references :waitlist_entry, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket_type, null: false, foreign_key: { on_delete: :restrict }
      t.references :pricing_tier, foreign_key: { on_delete: :restrict }
      t.references :order, foreign_key: { on_delete: :restrict }
      t.integer :quantity, null: false
      t.integer :unit_price_cents, null: false
      t.integer :status, null: false, default: 0
      t.integer :token_version, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :converted_at
      t.timestamps
    end
    add_check_constraint :waitlist_offers, "quantity > 0", name: "waitlist_offers_quantity_positive"
    add_check_constraint :waitlist_offers, "unit_price_cents >= 0", name: "waitlist_offers_price_nonnegative"
    add_check_constraint :waitlist_offers, "status IN (0, 1, 2, 3, 4)", name: "waitlist_offers_status_valid"
    add_index :waitlist_offers, :waitlist_entry_id, unique: true, where: "status IN (0, 1)",
      name: "index_waitlist_offers_one_active"
    add_index :waitlist_offers, [:ticket_type_id, :status, :expires_at], name: "index_waitlist_offer_inventory"

    create_table :catalog_items do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      t.text :description
      t.integer :kind, null: false
      t.integer :price_cents, null: false, default: 0
      t.integer :minimum_price_cents
      t.integer :maximum_price_cents
      t.integer :inventory_quantity
      t.integer :quantity_sold, null: false, default: 0
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :catalog_items, "kind IN (1, 2, 3, 4)", name: "catalog_items_kind_valid"
    add_check_constraint :catalog_items, "price_cents >= 0 AND quantity_sold >= 0", name: "catalog_items_values_nonnegative"
    add_check_constraint :catalog_items, "inventory_quantity IS NULL OR inventory_quantity > 0",
      name: "catalog_items_inventory_positive"
    add_index :catalog_items, [:event_id, :active, :position]

    add_reference :order_items, :catalog_item, foreign_key: { on_delete: :restrict }
    add_column :order_items, :item_kind, :integer, null: false, default: 0
    add_column :order_items, :organizer_fee_cents, :integer, null: false, default: 0
    add_check_constraint :order_items, "item_kind IN (0, 1, 2, 3, 4)", name: "order_items_kind_valid"
    add_check_constraint :order_items,
      "(item_kind = 0 AND ticket_type_id IS NOT NULL AND catalog_item_id IS NULL) OR " \
        "(item_kind <> 0 AND ticket_type_id IS NULL AND catalog_item_id IS NOT NULL)",
      name: "order_items_catalog_or_ticket"
    add_check_constraint :order_items, "organizer_fee_cents >= 0", name: "order_items_organizer_fee_nonnegative"

    create_table :catalog_fulfillments do |t|
      t.references :order_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.datetime :fulfilled_at
      t.references :fulfilled_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.timestamps
    end
    add_check_constraint :catalog_fulfillments, "status IN (0, 1, 2)",
      name: "catalog_fulfillments_status_valid"

    create_table :catalog_item_holds do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :catalog_item, null: false, foreign_key: { on_delete: :restrict }
      t.integer :quantity, null: false
      t.integer :status, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end
    add_check_constraint :catalog_item_holds, "quantity > 0", name: "catalog_item_holds_quantity_positive"
    add_check_constraint :catalog_item_holds, "status IN (0, 1, 2, 3)", name: "catalog_item_holds_status_valid"
    add_index :catalog_item_holds, [:catalog_item_id, :status, :expires_at], name: "index_catalog_item_hold_inventory"

    add_column :orders, :fee_policy_snapshot, :integer, null: false, default: 0
    add_column :orders, :buyer_fee_percent_snapshot, :integer, null: false, default: 100
    add_column :orders, :organizer_fee_cents, :integer, null: false, default: 0
    add_check_constraint :orders, "fee_policy_snapshot IN (0, 1, 2)", name: "orders_fee_policy_snapshot_valid"
    add_check_constraint :orders, "buyer_fee_percent_snapshot BETWEEN 0 AND 100",
      name: "orders_buyer_fee_percent_snapshot_valid"
    add_check_constraint :orders, "organizer_fee_cents >= 0", name: "orders_organizer_fee_nonnegative"

    create_table :registration_questions do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.string :prompt, null: false
      t.integer :kind, null: false, default: 0
      t.boolean :required, null: false, default: false
      t.jsonb :options, null: false, default: []
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :registration_questions, "kind IN (0, 1, 2, 3)",
      name: "registration_questions_kind_valid"
    add_index :registration_questions, [:event_id, :active, :position]

    create_table :event_waivers do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.string :title, null: false
      t.text :body, null: false
      t.string :version, null: false
      t.string :content_digest, null: false
      t.boolean :required, null: false, default: true
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :event_waivers, [:event_id, :version], unique: true

    create_table :registration_responses do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :registration_question, null: false, foreign_key: { on_delete: :restrict }
      t.string :prompt_snapshot, null: false
      t.integer :kind_snapshot, null: false
      t.jsonb :answer, null: false, default: {}
      t.datetime :answered_at, null: false
      t.timestamps
    end
    add_index :registration_responses, [:order_id, :registration_question_id], unique: true,
      name: "index_registration_responses_unique"

    create_table :waiver_acceptances do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :event_waiver, null: false, foreign_key: { on_delete: :restrict }
      t.string :version, null: false
      t.string :content_digest, null: false
      t.datetime :accepted_at, null: false
      t.timestamps
    end
    add_index :waiver_acceptances, [:order_id, :event_waiver_id], unique: true

    create_table :promoters do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      t.string :email
      t.string :code, null: false
      t.integer :commission_bps, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :promoters, "commission_bps BETWEEN 0 AND 10000", name: "promoters_commission_valid"
    add_index :promoters, [:event_id, :code], unique: true

    create_table :referral_attributions do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :promoter, null: false, foreign_key: { on_delete: :restrict }
      t.string :code_snapshot, null: false
      t.string :source
      t.string :medium
      t.string :campaign
      t.datetime :attributed_at, null: false
      t.timestamps
    end

    create_table :promoter_commission_entries do |t|
      t.references :promoter, null: false, foreign_key: { on_delete: :restrict }
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :refund, foreign_key: { on_delete: :restrict }
      t.integer :kind, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.string :idempotency_key, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_check_constraint :promoter_commission_entries, "kind IN (0, 1, 2)",
      name: "promoter_commission_entries_kind_valid"
    add_check_constraint :promoter_commission_entries, "amount_cents <> 0",
      name: "promoter_commission_entries_amount_nonzero"
    add_index :promoter_commission_entries, :idempotency_key, unique: true,
      name: "index_promoter_commission_entries_idempotency"

    create_table :communication_campaigns do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :name, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.jsonb :segment, null: false, default: { "type" => "all_attendees" }
      t.integer :status, null: false, default: 0
      t.datetime :scheduled_at
      t.datetime :started_at
      t.datetime :sent_at
      t.integer :recipient_count, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :communication_campaigns, "status IN (0, 1, 2, 3, 4, 5)",
      name: "communication_campaigns_status_valid"
    add_index :communication_campaigns, [:status, :scheduled_at]
    add_reference :message_deliveries, :communication_campaign,
      foreign_key: { on_delete: :restrict }, index: true
  end
end
