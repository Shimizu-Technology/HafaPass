class AddClerkProfileCheckedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :clerk_profile_checked_at, :datetime
  end
end
