# frozen_string_literal: true

# The minimal verified identity of a signed refund or dispute notice, kept
# outside its payload (A1-R1 review finding 5). Retention and privacy
# requests clear webhook_events.payload and reconciliation_exceptions.details,
# so an unbound notice could no longer be matched to the payment it
# describes. These are provider identifiers and amounts, not personal data.
# Additive and nullable: the running release never writes them.
class AddProviderIdentityToWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_events, :provider_payment_intent_id, :string
    add_column :webhook_events, :provider_object_id, :string
    add_column :webhook_events, :provider_livemode, :boolean
    add_column :webhook_events, :provider_account_id, :string
    add_column :webhook_events, :provider_amount_cents, :bigint
    add_column :webhook_events, :provider_currency, :string
  end
end
