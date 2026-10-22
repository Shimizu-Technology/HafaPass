# frozen_string_literal: true

class WaitlistUnsubscribe
  def self.token(entry)
    Rails.application.message_verifier(:waitlist_unsubscribe).generate(
      [entry.id, entry.management_version], purpose: :waitlist_unsubscribe
    )
  end

  def self.from_token(token)
    id, version = Rails.application.message_verifier(:waitlist_unsubscribe).verified(
      token, purpose: :waitlist_unsubscribe
    )
    entry = WaitlistEntry.find_by(id: id)
    entry if entry && entry.management_version == version
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.stop!(entry, all: false)
    WaitlistLocks.with(entry: entry) do
      if entry.active?
        entry.waitlist_offers.where(status: [:offered, :claimed]).find_each do |offer|
          offer.update!(status: :cancelled, token_version: offer.token_version + 1,
            cancel_reason: "Buyer stopped waitlist alerts") unless offer.order_id
        end
        entry.update!(status: :cancelled, expires_at: nil, delivery_failure: nil)
      end
    end
    return unless all

    organization = entry.event.organization
    organization.with_lock do
      MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: entry.email)
        .update!(unsubscribed_at: Time.current)
    end
    WaitlistEntry.joins(:event).where(events: { organization_id: organization.id })
      .where("LOWER(waitlist_entries.email) = ?", entry.email.downcase).where(status: [:waiting, :notified, :offered]).find_each { |other| stop!(other) }
  end
end
