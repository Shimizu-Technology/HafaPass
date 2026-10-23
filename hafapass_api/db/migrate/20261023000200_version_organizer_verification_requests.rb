class VersionOrganizerVerificationRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :organizer_profiles, :verification_request_version, :integer, null: false, default: 0
    add_column :organizer_profiles, :verification_change_diff, :jsonb, null: false, default: {}
  end
end
