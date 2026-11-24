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
    ids += OrganizerFollow.where(email_opted_in_address: email).pluck(:organization_id)
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
    enabled += OrganizerFollow.where(organization_id: ids, email_opted_in_address: email).where.not(email_opted_in_at: nil).pluck(:organization_id)
    enabled.uniq - blocked
  end

  # All platform consent writes take these locks in this order, including creation.
  def self.with_platform_locks(email, create_subscriber: false, subscriber_attributes: {})
    email = email.to_s.strip.downcase
    preference = EmailPreference.find_or_create_by!(email: email)
    preference.with_lock do
      subscriber = PlatformSubscriber.find_by(email: email)
      if subscriber.nil? && create_subscriber
        subscriber = PlatformSubscriber.create!(subscriber_attributes.merge(email: email))
      end
      if subscriber
        subscriber.with_lock { yield preference, subscriber }
      else
        yield preference, nil
      end
    end
  end

  # Caller holds the preference and (when present) subscriber locks.
  # Materialize global withdrawal into each other scope before lifting it.
  def self.restore_scope!(preference:, subscriber:, organization: nil)
    if preference.all_unsubscribed?
      organizations(preference.email).find_each do |org|
        next if org == organization

        MarketingUnsubscribe.find_or_initialize_by(organization: org, email: preference.email).update!(unsubscribed_at: Time.current)
      end
      unsubscribe_locked_platform!(preference.email, subscriber) if organization && subscriber
      preference.update!(all_unsubscribed: false)
    end
    MarketingUnsubscribe.where(organization: organization, email: preference.email).delete_all if organization
  end

  def self.unsubscribe_platform!(email)
    with_platform_locks(email, create_subscriber: true, subscriber_attributes: { source: "preferences" }) do |preference, subscriber|
      unsubscribe_locked_platform!(preference.email, subscriber)
    end
  end

  def self.unsubscribe_locked_platform!(email, subscriber)
    subscriber.update!(status: "unsubscribed", confirmation_nonce: SecureRandom.hex(24))
    EmailConsent.record!(email: email, scope: "platform", action: "unsubscribed", source: "preferences")
  end
end
