# frozen_string_literal: true

class CreateAnnualTaxThresholds < ActiveRecord::Migration[8.0]
  class Threshold < ActiveRecord::Base
    self.table_name = "annual_tax_thresholds"
  end

  def up
    create_table :annual_tax_thresholds do |t|
      t.integer :year, null: false
      t.string :form_type, null: false
      t.integer :amount_cents, null: false
      t.integer :transaction_count
      t.timestamps
      t.index [:year, :form_type], unique: true
    end
    (2000..2100).each do |year|
      %w[1099-nec 1099-misc].each do |form|
        Threshold.create!(year: year, form_type: form, amount_cents: year < 2026 ? 60_000 : 200_000)
      end
      Threshold.create!(year: year, form_type: "1099-k", amount_cents: 2_000_000, transaction_count: 200)
    end
  end

  def down
    drop_table :annual_tax_thresholds
  end
end
