class FreezeMessageTransportContext < ActiveRecord::Migration[8.0]
  def change
    add_column :message_deliveries, :transport_context_digest, :string
  end
end
