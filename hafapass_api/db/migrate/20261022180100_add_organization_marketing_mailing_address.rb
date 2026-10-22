# frozen_string_literal: true

class AddOrganizationMarketingMailingAddress < ActiveRecord::Migration[8.0]
  def change
    add_column :organizations, :marketing_mailing_address, :text
    add_column :organizations, :marketing_address_certified_at, :datetime
  end
end
