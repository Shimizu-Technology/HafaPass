# frozen_string_literal: true

class PinEmailConsentIdentity < ActiveRecord::Migration[8.1]
  def change
    # Legacy follows have no trustworthy address snapshot. Require fresh consent.
    add_column :organizer_follows, :email_opted_in_address, :string
    add_column :orders, :platform_opt_in_at, :datetime
  end
end
