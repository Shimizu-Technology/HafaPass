class CreateSiteSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :site_settings do |t|
      # Payment configuration
      t.string :payment_mode, null: false, default: 'simulate'

      # Platform info
      t.string :platform_name, default: 'HafaPass'
      t.string :platform_email, default: 'tickets@hafapass.com'
      t.string :platform_phone

      # Fee configuration
      t.decimal :service_fee_percent, precision: 5, scale: 2, default: 3.0
      t.integer :service_fee_flat_cents, default: 50

      t.timestamps
    end
  end
end
