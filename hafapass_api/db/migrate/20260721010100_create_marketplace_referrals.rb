# frozen_string_literal: true

class CreateMarketplaceReferrals < ActiveRecord::Migration[8.1]
  def change
    create_table :event_referrals do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.string :code, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :event_referrals, :code, unique: true
    add_index :event_referrals, [:user_id, :event_id], unique: true

    add_reference :marketplace_funnel_events, :event_referral, foreign_key: { on_delete: :restrict }
    add_reference :acquisition_attributions, :event_referral, foreign_key: { on_delete: :restrict }
  end
end
