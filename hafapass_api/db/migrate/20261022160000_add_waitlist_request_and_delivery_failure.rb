class AddWaitlistRequestAndDeliveryFailure < ActiveRecord::Migration[7.2]
  def change
    add_column :waitlist_entries, :requested_at, :datetime
    add_column :waitlist_entries, :request_ip, :string
    add_column :waitlist_entries, :request_user_agent, :text
    add_column :waitlist_entries, :delivery_failure, :string
    add_column :waitlist_offers, :cancel_reason, :string

    reversible do |direction|
      direction.up do
        execute "UPDATE waitlist_entries SET requested_at = created_at WHERE requested_at IS NULL"
      end
    end
  end
end
