class FreezeMessageWireBody < ActiveRecord::Migration[8.0]
  def change
    add_column :message_deliveries, :outbound_wire_body, :text
    add_column :message_deliveries, :wire_body_digest, :string
    add_check_constraint :message_deliveries, <<~SQL.squish, name: "message_deliveries_wire_digest_matches"
      (outbound_wire_body IS NULL AND wire_body_digest IS NULL) OR
      (outbound_wire_body IS NOT NULL AND wire_body_digest IS NOT NULL AND
       wire_body_digest = encode(sha256(convert_to(outbound_wire_body, 'UTF8')), 'hex'))
    SQL
  end
end
