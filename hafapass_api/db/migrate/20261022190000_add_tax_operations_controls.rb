# frozen_string_literal: true

class AddTaxOperationsControls < ActiveRecord::Migration[8.0]
  def change
    change_table :organizer_tax_informations, bulk: true do |t|
      t.string :tin_match_status, default: "unverified", null: false
      t.integer :tin_match_result_code
      t.datetime :tin_matched_at
      t.string :b_notice_stage
      t.datetime :b_notice_sent_at
      t.date :b_notice_response_due_on
      t.boolean :backup_withholding_flag, default: false, null: false
      t.text :backup_withholding_reason
    end
    add_check_constraint :organizer_tax_informations,
      "tin_match_status IN ('unverified', 'matched', 'missing_or_invalid', 'not_issued', 'mismatch', 'invalid_request', 'duplicate', 'matched_ssn', 'matched_ein', 'matched_both')",
      name: "tax_information_tin_match_status_valid"

    create_table :tin_match_requests do |t|
      t.references :organizer_tax_information, null: false, foreign_key: true
      t.string :account_reference, null: false
      t.datetime :tax_information_updated_at, null: false
      t.datetime :exported_at, null: false
      t.datetime :imported_at
      t.integer :result_code
      t.timestamps
      t.index :account_reference, unique: true
    end

    add_column :site_settings, :backup_withholding_mode, :string, default: "block", null: false
    add_column :site_settings, :backup_withholding_rate_bps, :integer, default: 2400, null: false
    add_column :site_settings, :tax_reporting_thresholds, :jsonb,
      default: { "1099-nec" => 200_000, "1099-misc" => 200_000, "1099-k" => 2_000_000 }, null: false
    add_check_constraint :site_settings, "backup_withholding_mode IN ('block', 'withhold')",
      name: "site_settings_backup_withholding_mode_valid"

    add_column :payouts, :withheld_cents, :integer, default: 0, null: false
    add_column :payouts, :withholding_rate_bps, :integer, default: 0, null: false
    add_column :payouts, :withholding_reason, :string
    add_column :payouts, :withholding_override_reason, :text
    add_check_constraint :payouts, "withheld_cents >= 0 AND withheld_cents < amount_cents",
      name: "payouts_withholding_valid"

    create_table :annual_tax_report_settings do |t|
      t.references :organization, null: false, foreign_key: true
      t.integer :year, null: false
      t.string :form_type, default: "review_required", null: false
      t.string :jurisdiction, default: "irs", null: false
      t.timestamps
      t.index [:organization_id, :year], unique: true
      t.check_constraint "form_type IN ('review_required', '1099-nec', '1099-misc', '1099-k', 'none')",
        name: "annual_tax_report_form_valid"
      t.check_constraint "jurisdiction IN ('irs', 'guam_drt')", name: "annual_tax_report_jurisdiction_valid"
    end
  end
end
