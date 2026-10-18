class AddPaymentPlatformAccountContext < ActiveRecord::Migration[8.0]
  def change
    add_column :payments, :provider_platform_account_id, :string
  end
end
