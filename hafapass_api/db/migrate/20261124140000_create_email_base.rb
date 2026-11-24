class CreateEmailBase < ActiveRecord::Migration[8.0]
  def change
    create_table :platform_subscribers do |t|
      t.string :email, null: false
      t.string :name
      t.string :status, null: false, default: 'pending'
      t.string :source, null: false
      t.jsonb :interests, null: false, default: []
      t.jsonb :villages, null: false, default: []
      t.string :confirmation_nonce, null: false
      t.datetime :confirmed_at
      t.timestamps
    end
    add_index :platform_subscribers, :email, unique: true
    create_table :email_consents do |t|
      t.string :email, null: false
      t.references :organization, foreign_key: true
      t.string :scope, null: false
      t.string :action, null: false
      t.string :version, null: false
      t.string :source, null: false
      t.string :ip
      t.string :user_agent
      t.timestamps
    end
    add_index :email_consents, [:email, :created_at]
    create_table :email_preferences do |t|
      t.string :email, null: false
      t.boolean :all_unsubscribed, null: false, default: false
      t.timestamps
    end
    add_index :email_preferences, :email, unique: true
    add_column :organizer_follows, :email_opted_in_at, :datetime
    add_column :organizer_follows, :email_consent_version, :string
    create_table :audience_mailings do |t|
      t.references :organization, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :subject, null: false
      t.text :body, null: false
      t.string :audience, null: false
      t.string :status, null: false, default: 'draft'
      t.datetime :scheduled_at
      t.bigint :cursor, null: false, default: 0
      t.timestamps
    end
    create_table :email_rate_slots do |t|
      t.string :name, null: false
      t.datetime :available_at, null: false
    end
    add_index :email_rate_slots, :name, unique: true
  end
end
