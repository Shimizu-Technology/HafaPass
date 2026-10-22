# frozen_string_literal: true

class AddVerifiedEmailsToPrivacyRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :privacy_requests, :verified_emails, :jsonb, default: [], null: false
  end
end
