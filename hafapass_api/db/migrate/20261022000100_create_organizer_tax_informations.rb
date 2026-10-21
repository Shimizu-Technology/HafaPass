# frozen_string_literal: true

class CreateOrganizerTaxInformations < ActiveRecord::Migration[8.0]
  def change
    create_table :organizer_tax_informations do |t|
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.string :legal_name, null: false
      t.string :business_name
      t.string :tax_classification, null: false
      t.string :tin_type, null: false
      t.text :tin, null: false
      t.string :tin_last_four, null: false, limit: 4
      t.text :mailing_address, null: false
      t.string :exempt_payee_code
      t.string :signer_name, null: false
      t.datetime :certified_at, null: false
      t.string :certification_version, null: false
      t.timestamps
    end
  end
end
