# frozen_string_literal: true

class KeyAnnualTaxSettingsByPayee < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :annual_tax_report_settings, :payee_key, :string, default: "all", null: false
    remove_index :annual_tax_report_settings, [:organization_id, :year], algorithm: :concurrently
    add_index :annual_tax_report_settings, [:organization_id, :year, :payee_key], unique: true,
      name: "idx_annual_tax_settings_on_payee_year", algorithm: :concurrently
  end
end
