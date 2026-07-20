# frozen_string_literal: true

class CreateOrganizationsAndSettlements < ActiveRecord::Migration[8.1]
  def up
    create_organizations
    create_memberships_and_assignments
    attach_existing_organizers
    create_connected_accounts
    backfill_existing_organizers
    create_financial_tables
    create_audit_logs
  end

  def down
    drop_table :audit_logs
    drop_table :payouts
    drop_table :settlement_items
    drop_table :settlements
    drop_table :balance_adjustments
    drop_table :connected_accounts
    remove_reference :events, :organization
    remove_reference :organizer_profiles, :organization
    drop_table :event_staff_assignments
    drop_table :organization_memberships
    drop_table :organizations
  end

  private

  def create_organizations
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.integer :status, null: false, default: 0
      t.string :timezone, null: false, default: "Pacific/Guam"
      t.string :currency, null: false, default: "usd"
      t.timestamps
    end
    add_index :organizations, :slug, unique: true
    add_check_constraint :organizations, "status IN (0, 1, 2)", name: "organizations_status_valid"
    add_check_constraint :organizations, "char_length(currency) = 3", name: "organizations_currency_length"
  end

  def create_memberships_and_assignments
    create_table :organization_memberships do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: true, foreign_key: { on_delete: :restrict }
      t.references :invited_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :role, null: false
      t.integer :status, null: false, default: 0
      t.string :invited_email
      t.integer :invitation_version, null: false, default: 1
      t.datetime :invited_at
      t.datetime :accepted_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :organization_memberships, [:organization_id, :user_id], unique: true, where: "user_id IS NOT NULL",
      name: "idx_organization_memberships_unique_user"
    add_index :organization_memberships, "organization_id, lower(invited_email)", unique: true,
      where: "invited_email IS NOT NULL AND status = 0", name: "idx_organization_memberships_unique_invite"
    add_check_constraint :organization_memberships, "role IN (0, 1, 2, 3, 4, 5)",
      name: "organization_memberships_role_valid"
    add_check_constraint :organization_memberships, "status IN (0, 1, 2)",
      name: "organization_memberships_status_valid"
    add_check_constraint :organization_memberships, "invitation_version > 0",
      name: "organization_memberships_invitation_version_positive"
    add_check_constraint :organization_memberships,
      "user_id IS NOT NULL OR invited_email IS NOT NULL",
      name: "organization_memberships_identity_present"

    create_table :event_staff_assignments do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :assigned_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :role, null: false
      t.integer :status, null: false, default: 0
      t.datetime :expires_at
      t.timestamps
    end
    add_index :event_staff_assignments, [:event_id, :user_id, :role], unique: true,
      name: "idx_event_staff_assignments_unique_role"
    add_check_constraint :event_staff_assignments, "role IN (0, 1, 2)",
      name: "event_staff_assignments_role_valid"
    add_check_constraint :event_staff_assignments, "status IN (0, 1)",
      name: "event_staff_assignments_status_valid"
  end

  def attach_existing_organizers
    add_reference :organizer_profiles, :organization, null: true,
      foreign_key: { on_delete: :restrict }, index: { unique: true }
    add_reference :events, :organization, null: true, foreign_key: { on_delete: :restrict }
  end

  def create_connected_accounts
    create_table :connected_accounts do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.string :provider, null: false
      t.string :provider_account_id
      t.integer :status, null: false, default: 0
      t.boolean :charges_enabled, null: false, default: false
      t.boolean :payouts_enabled, null: false, default: false
      t.boolean :details_submitted, null: false, default: false
      t.jsonb :requirements_due, null: false, default: []
      t.jsonb :capabilities, null: false, default: {}
      t.string :country, null: false, default: "GU"
      t.string :currency, null: false, default: "usd"
      t.datetime :last_synced_at
      t.timestamps
    end
    add_index :connected_accounts, [:organization_id, :provider], unique: true
    add_index :connected_accounts, [:provider, :provider_account_id], unique: true,
      where: "provider_account_id IS NOT NULL", name: "idx_connected_accounts_unique_provider_id"
    add_check_constraint :connected_accounts, "provider IN ('paypal', 'manual', 'stripe', 'legacy_manual')",
      name: "connected_accounts_provider_valid"
    add_check_constraint :connected_accounts, "status IN (0, 1, 2, 3, 4, 5)",
      name: "connected_accounts_status_valid"
    add_check_constraint :connected_accounts, "char_length(currency) = 3",
      name: "connected_accounts_currency_length"
  end

  def backfill_existing_organizers
    execute <<~SQL.squish
      INSERT INTO organizations (name, slug, status, timezone, currency, created_at, updated_at)
      SELECT business_name, 'legacy-organizer-' || id, 0, 'Pacific/Guam', 'usd', created_at, updated_at
      FROM organizer_profiles
    SQL
    execute <<~SQL.squish
      UPDATE organizer_profiles
      SET organization_id = organizations.id
      FROM organizations
      WHERE organizations.slug = 'legacy-organizer-' || organizer_profiles.id
    SQL
    execute <<~SQL.squish
      INSERT INTO organization_memberships
        (organization_id, user_id, role, status, accepted_at, created_at, updated_at)
      SELECT organization_id, user_id, 0, 1, created_at, created_at, updated_at
      FROM organizer_profiles
    SQL
    execute <<~SQL.squish
      UPDATE events
      SET organization_id = organizer_profiles.organization_id
      FROM organizer_profiles
      WHERE organizer_profiles.id = events.organizer_profile_id
    SQL
    execute <<~SQL.squish
      INSERT INTO connected_accounts
        (organization_id, provider, provider_account_id, status, charges_enabled, payouts_enabled,
         details_submitted, requirements_due, capabilities, country, currency, last_synced_at, created_at, updated_at)
      SELECT organization_id, 'legacy_manual', stripe_account_id, 3, TRUE, TRUE,
             TRUE, '[]'::jsonb, '{"legacy_backfill":true}'::jsonb, 'GU', 'usd', updated_at, created_at, updated_at
      FROM organizer_profiles
      WHERE payout_ready = TRUE
    SQL
    change_column_null :organizer_profiles, :organization_id, false
    change_column_null :events, :organization_id, false
  end

  def create_financial_tables
    create_table :balance_adjustments do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: true, foreign_key: { on_delete: :restrict }
      t.references :order, null: true, foreign_key: { on_delete: :restrict }
      t.references :dispute, null: true, foreign_key: { on_delete: :restrict }
      t.references :created_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :reversed_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :reversal_of, null: true, foreign_key: { to_table: :balance_adjustments, on_delete: :restrict }
      t.string :kind, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.text :reason, null: false
      t.datetime :effective_at, null: false
      t.timestamps
    end
    add_index :balance_adjustments, :reversal_of_id, unique: true,
      where: "reversal_of_id IS NOT NULL", name: "idx_balance_adjustments_one_reversal"
    add_check_constraint :balance_adjustments, "amount_cents <> 0", name: "balance_adjustments_amount_nonzero"
    add_check_constraint :balance_adjustments, "status IN (0, 1, 2)", name: "balance_adjustments_status_valid"
    add_check_constraint :balance_adjustments, "char_length(currency) = 3",
      name: "balance_adjustments_currency_length"

    create_table :settlements do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.integer :version, null: false
      t.integer :status, null: false, default: 0
      t.string :currency, null: false, default: "usd"
      t.string :source_digest, null: false
      t.integer :gross_cents, null: false, default: 0
      t.integer :discount_cents, null: false, default: 0
      t.integer :refund_cents, null: false, default: 0
      t.integer :net_cents, null: false, default: 0
      t.integer :platform_fee_cents, null: false, default: 0
      t.integer :processing_fee_cents, null: false, default: 0
      t.integer :organizer_proceeds_cents, null: false, default: 0
      t.integer :reserve_cents, null: false, default: 0
      t.integer :adjustment_cents, null: false, default: 0
      t.integer :payable_cents, null: false, default: 0
      t.integer :paid_cents, null: false, default: 0
      t.integer :negative_balance_cents, null: false, default: 0
      t.datetime :calculated_at, null: false
      t.datetime :finalized_at
      t.timestamps
    end
    add_index :settlements, [:event_id, :version], unique: true
    add_index :settlements, [:event_id, :source_digest], unique: true
    add_check_constraint :settlements, "status IN (0, 1)", name: "settlements_status_valid"
    add_check_constraint :settlements, "version > 0", name: "settlements_version_positive"
    add_check_constraint :settlements, "char_length(currency) = 3", name: "settlements_currency_length"
    %w[gross discount refund net platform_fee processing_fee organizer_proceeds reserve payable paid negative_balance].each do |name|
      add_check_constraint :settlements, "#{name}_cents >= 0", name: "settlements_#{name}_nonnegative"
    end

    create_table :settlement_items do |t|
      t.references :settlement, null: false, foreign_key: { on_delete: :restrict }
      t.string :kind, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.string :source_type
      t.bigint :source_id
      t.string :description, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :settlement_items, [:source_type, :source_id]
    add_index :settlement_items, [:settlement_id, :kind, :source_type, :source_id], unique: true,
      where: "source_id IS NOT NULL", name: "idx_settlement_items_unique_source"
    add_check_constraint :settlement_items, "char_length(currency) = 3", name: "settlement_items_currency_length"

    create_table :payouts do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :settlement, null: false, foreign_key: { on_delete: :restrict }
      t.references :connected_account, null: false, foreign_key: { on_delete: :restrict }
      t.string :provider, null: false
      t.string :provider_payout_id
      t.string :idempotency_key, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :failure_code
      t.text :failure_message
      t.datetime :initiated_at
      t.datetime :paid_at
      t.timestamps
    end
    add_index :payouts, :idempotency_key, unique: true
    add_index :payouts, [:provider, :provider_payout_id], unique: true,
      where: "provider_payout_id IS NOT NULL", name: "idx_payouts_unique_provider_id"
    add_check_constraint :payouts, "amount_cents > 0", name: "payouts_amount_positive"
    add_check_constraint :payouts, "status IN (0, 1, 2, 3, 4)", name: "payouts_status_valid"
    add_check_constraint :payouts, "char_length(currency) = 3", name: "payouts_currency_length"
  end

  def create_audit_logs
    create_table :audit_logs do |t|
      t.references :organization, null: true, foreign_key: { on_delete: :restrict }
      t.references :actor_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :action, null: false
      t.string :auditable_type, null: false
      t.bigint :auditable_id, null: false
      t.jsonb :before_data, null: false, default: {}
      t.jsonb :after_data, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :request_id
      t.inet :ip_address
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :audit_logs, [:auditable_type, :auditable_id, :occurred_at], name: "idx_audit_logs_auditable_time"
    add_index :audit_logs, [:organization_id, :occurred_at]
  end
end
