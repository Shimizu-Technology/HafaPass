class AddOrganizerVerificationContactAndEventPreview < ActiveRecord::Migration[8.0]
  def change
    add_column :organizer_profiles, :verification_phone, :string
    add_column :organizer_profiles, :verification_link, :string
    add_column :organizer_profiles, :verification_request_note, :text
    add_column :events, :preview_token_digest, :string
    add_column :events, :preview_token_version, :integer, default: 0, null: false
  end
end
