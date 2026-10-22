# frozen_string_literal: true

class AddTaxIdentityDigests < ActiveRecord::Migration[8.0]
  def up
    add_column :organizer_tax_informations, :tin_digest, :string
    add_column :organizer_tax_informations, :validation_identity_digest, :string
    add_column :organizer_tax_informations, :tin_match_identity_digest, :string
    add_column :organizer_tax_informations, :b_notice_identity_digest, :string
    add_index :organizer_tax_informations, :tin_digest

    # Existing encrypted W-9s must be searchable before text screening begins.
    OrganizerTaxInformation.reset_column_information
    OrganizerTaxInformation.find_each do |tax|
      tax.update_columns(tin_digest: OrganizerTaxInformation.tin_digest_for(tax.tin))
    end
  end

  def down
    remove_index :organizer_tax_informations, :tin_digest
    remove_column :organizer_tax_informations, :validation_identity_digest
    remove_column :organizer_tax_informations, :tin_match_identity_digest
    remove_column :organizer_tax_informations, :b_notice_identity_digest
    remove_column :organizer_tax_informations, :tin_digest
  end
end
