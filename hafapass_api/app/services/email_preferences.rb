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
    !EmailPreference.blocked?(email) && !MarketingUnsubscribe.exists?(organization: organization, email: email) &&
      (MarketingConsent.opted_in?(organization: organization, email: email) ||
        EmailConsent.where(email: email, organization: organization, scope: "organizer").order(created_at: :desc, id: :desc).first&.action == "confirmed" ||
        OrganizerFollow.joins(:user).where(organization: organization).where.not(email_opted_in_at: nil)
          .where("LOWER(users.email) = ?", email).exists?)
  end

  def self.unsubscribe_platform!(email)
    PlatformSubscriber.find_by(email: email)&.update!(status: "unsubscribed", confirmation_nonce: SecureRandom.hex(24))
    EmailConsent.record!(email: email, scope: "platform", action: "unsubscribed", source: "preferences")
  end
end
