# frozen_string_literal: true

class CreateOrganizationInvitationDispatches < ActiveRecord::Migration[8.0]
  def change
    create_table :organization_invitation_dispatches do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :recipient, null: false
      t.datetime :created_at, null: false
    end
    add_index :organization_invitation_dispatches, [:actor_user_id, :created_at], name: "index_invitation_dispatches_actor_time"
    add_index :organization_invitation_dispatches, [:organization_id, :created_at], name: "index_invitation_dispatches_org_time"
    add_index :organization_invitation_dispatches, [:organization_id, :recipient, :created_at], name: "index_invitation_dispatches_recipient_time"
  end
end
