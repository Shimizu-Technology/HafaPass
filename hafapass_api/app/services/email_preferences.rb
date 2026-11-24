# frozen_string_literal: true

class EmailPreferences
  def self.token(email, scope: "preferences")
    encryptor.encrypt_and_sign([email.to_s.strip.downcase, scope], purpose: scope)
  end

  def self.email(token, scope: "preferences")
    value = begin
      encryptor.decrypt_and_verify(token, purpose: scope)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      Rails.application.message_verifier(:email_preferences).verified(token, purpose: scope)
    end
    value[0] if value.is_a?(Array) && value[1] == scope && value[0].is_a?(String) && value[0].match?(URI::MailTo::EMAIL_REGEXP)
  end

  def self.encryptor
    ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key("email-preferences", 32), url_safe: true)
  end

  def self.url(email)
    "#{PublicSiteUrl.frontend}/email-preferences/#{ERB::Util.url_encode(token(email))}"
  end

  def self.organizations(email)
    ids = Order.joins(:event).where("LOWER(buyer_email) = ?", email).pluck("events.organization_id")
    ids += OrganizerFollow.joins(:user).where("LOWER(users.email) = ?", email).pluck(:organization_id)
    ids += EmailConsent.where(email: email).where.not(organization_id: nil).pluck(:organization_id)
    ids += MarketingUnsubscribe.where(email: email).pluck(:organization_id)
    ids += WaitlistEntry.joins(:event).where("LOWER(waitlist_entries.email) = ?", email).pluck("events.organization_id")
    Organization.where(id: ids.uniq)
  end

  def self.organizer_enabled?(organization, email)
    organizer_enabled_ids([organization.id], email).include?(organization.id)
  end

  # Share sending eligibility with the account listing without per-organizer queries.
  def self.organizer_enabled_ids(ids, email)
    email = email.to_s.strip.downcase
    return [] if EmailPreference.blocked?(email)

    blocked = MarketingUnsubscribe.where(organization_id: ids, email: email).pluck(:organization_id)
    orders = Order.joins(:event).where(events: { organization_id: ids }, status: [:completed, :partially_refunded, :refunded])
      .where("LOWER(orders.buyer_email) = ?", email)
      .select("DISTINCT ON (events.organization_id) orders.*, events.organization_id AS consent_organization_id")
      .order(Arel.sql("events.organization_id, orders.created_at DESC, orders.id DESC"))
    enabled = orders.filter_map { |order| order.consent_organization_id if order.marketing_opt_in? }
    enabled += EmailConsent.where(email: email, organization_id: ids, scope: "organizer")
      .select("DISTINCT ON (organization_id) organization_id, action")
      .order(:organization_id, created_at: :desc, id: :desc).filter_map { |row| row.organization_id if row.action == "confirmed" }
    enabled += OrganizerFollow.joins(:user).where(organization_id: ids).where.not(email_opted_in_at: nil)
      .where("LOWER(users.email) = ?", email).pluck(:organization_id)
    enabled.uniq - blocked
  end

  def self.unsubscribe_platform!(email)
    subscriber = PlatformSubscriber.find_or_create_by!(email: email) { |row| row.source = "preferences" }
    subscriber.with_lock do
      subscriber.update!(status: "unsubscribed", confirmation_nonce: SecureRandom.hex(24))
      EmailConsent.record!(email: email, scope: "platform", action: "unsubscribed", source: "preferences")
    end
  end
end
