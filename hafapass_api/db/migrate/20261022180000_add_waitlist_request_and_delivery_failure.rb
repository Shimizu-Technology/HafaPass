class AddWaitlistRequestAndDeliveryFailure < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :waitlist_entries, :requested_at, :datetime
    add_column :waitlist_entries, :request_ip, :string
    add_column :waitlist_entries, :request_user_agent, :text
    add_column :waitlist_entries, :delivery_failure, :string
    add_column :waitlist_offers, :cancel_reason, :string

    reversible do |direction|
      direction.up do
        waitlist_entries = Class.new(ActiveRecord::Base) do
          self.table_name = "waitlist_entries"
        end

        waitlist_entries.where(requested_at: nil).in_batches(of: 1_000) do |batch|
          batch.update_all("requested_at = created_at")
        end
      end
    end
  end
end
