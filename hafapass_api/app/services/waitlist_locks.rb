# frozen_string_literal: true

# All waitlist writers acquire row locks in this order: offer, entry, delivery.
class WaitlistLocks
  ADVISORY_NAMESPACE = 20_261_022

  def self.with(entry:, offer: nil, delivery: nil)
    WaitlistEntry.transaction do
      # Stabilize the active-offer lookup before taking any row lock. A new
      # offer can otherwise appear while this transaction waits for the entry.
      ApplicationRecord.connection.exec_query("SELECT 1 FROM pg_advisory_xact_lock($1, $2)", "Waitlist lock", [
        ActiveRecord::Relation::QueryAttribute.new("namespace", ADVISORY_NAMESPACE, ActiveRecord::Type::Integer.new),
        ActiveRecord::Relation::QueryAttribute.new("entry_id", entry.id, ActiveRecord::Type::Integer.new)
      ])
      offer ||= entry.waitlist_offers.where(status: [:offered, :claimed]).order(id: :desc).first
      offer&.lock!
      entry.lock!
      delivery&.lock!
      yield(offer, entry, delivery)
    end
  end

  def self.for_delivery(delivery, &block)
    return delivery.with_lock { yield(nil, nil, delivery) } unless %w[waitlist_offer waitlist_notification].include?(delivery.template)

    offer = WaitlistOffer.find_by(id: delivery.metadata["waitlist_offer_id"]) if delivery.template == "waitlist_offer"
    entry = offer&.waitlist_entry || WaitlistEntry.find_by(id: delivery.metadata["waitlist_entry_id"])
    return delivery.with_lock { yield(offer, nil, delivery) } unless entry

    with(entry: entry, offer: offer, delivery: delivery, &block)
  end
end
