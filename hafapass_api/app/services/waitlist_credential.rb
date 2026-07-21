# frozen_string_literal: true

class WaitlistCredential
  MANAGEMENT_NAMESPACE = "waitlist_management"
  OFFER_NAMESPACE = "waitlist_offer"

  class << self
    def management(entry)
      SignedCredential.issue(
        namespace: MANAGEMENT_NAMESPACE,
        payload: { entry_id: entry.id, version: entry.management_version },
        expires_at: [entry.event.ends_at || entry.event.starts_at, 30.days.from_now].compact.max
      )
    end

    def find_management(token)
      find(token, namespace: MANAGEMENT_NAMESPACE, model: WaitlistEntry, id_key: "entry_id",
        version_attribute: :management_version)
    end

    def offer(offer)
      SignedCredential.issue(
        namespace: OFFER_NAMESPACE,
        payload: { offer_id: offer.id, version: offer.token_version },
        expires_at: offer.expires_at
      )
    end

    def find_offer(token)
      find(token, namespace: OFFER_NAMESPACE, model: WaitlistOffer, id_key: "offer_id",
        version_attribute: :token_version)
    end

    private

    def find(token, namespace:, model:, id_key:, version_attribute:)
      payload = SignedCredential.verify(namespace: namespace, token: token)
      return unless payload

      record = model.find_by(id: payload[id_key])
      version = payload["version"]
      return unless record && ActiveSupport::SecurityUtils.secure_compare(record.public_send(version_attribute).to_s, version.to_s)

      record
    end
  end
end
