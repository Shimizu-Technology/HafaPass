# frozen_string_literal: true

class AddTranslationRequestedAtToTicketTypes < ActiveRecord::Migration[8.1]
  def change
    reversible { |direction| direction.up { execute "SET LOCAL lock_timeout = '5s'" } }
    add_column :ticket_types, :translation_requested_at, :datetime
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE ticket_types
          SET translation_requested_at = updated_at
          WHERE translation_status = 'pending'
        SQL
      end
    end
  end
end
