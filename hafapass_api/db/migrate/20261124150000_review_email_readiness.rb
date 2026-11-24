class ReviewEmailReadiness < ActiveRecord::Migration[8.1]
  def change
    add_column :audience_mailings, :filters, :jsonb, default: {}, null: false
    add_column :audience_mailings, :recipient_count, :integer, default: 0, null: false
    add_column :audience_mailings, :blocked_reason, :string
  end
end
