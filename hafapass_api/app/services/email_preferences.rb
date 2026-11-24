# frozen_string_literal: true

class EmailPreferences
  # Two-int key space, distinct from WaitlistLocks (20_261_022) and LegalHold (728314).
  ADVISORY_NAMESPACE = 20_261_124

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

  # Consent lock order: address advisory lock, preference, subscriber, follow,
  # organization/waitlist, then unsubscribe/consent rows.
  # For multiple addresses, nest each address's advisory/row locks in sorted order.
  # Lock-only callers must not manufacture new personal-data rows.
  def self.with_platform_locks(email, create_preference: true, create_subscriber: false, subscriber_attributes: {})
    email = email.to_s.strip.downcase
    EmailPreference.transaction do
      EmailPreference.connection.exec_query("SELECT 1 FROM pg_advisory_xact_lock($1, hashtext($2))", "Email consent lock", [
        ActiveRecord::Relation::QueryAttribute.new("namespace", ADVISORY_NAMESPACE, ActiveRecord::Type::Integer.new),
        ActiveRecord::Relation::QueryAttribute.new("email", email, ActiveRecord::Type::String.new)
      ])
      preference = create_preference ? EmailPreference.find_or_create_by!(email: email) : EmailPreference.find_by(email: email)
      preference&.lock!
      subscriber = PlatformSubscriber.find_by(email: email)
      if subscriber.nil? && create_subscriber && create_preference
        subscriber = PlatformSubscriber.create!(subscriber_attributes.merge(email: email))
      end
      subscriber&.lock!
      yield preference, subscriber
    end
  end

  def self.with_platform_locks_for(emails, create_preference: true, &block)
    addresses = emails.compact.map { |email| email.to_s.strip.downcase }.reject(&:blank?).uniq.sort
    return yield if addresses.empty?

    with_platform_locks(addresses.first, create_preference: create_preference) do
      with_platform_locks_for(addresses.drop(1), create_preference: create_preference, &block)
    end
  end

  # Caller holds the preference and (when present) subscriber locks.
  # Materialize global withdrawal into each other scope before lifting it.
  def self.restore_scope!(preference:, subscriber:, organization: nil)
    lock_follows!(preference.email)
    if preference.all_unsubscribed?
      organizations(preference.email).find_each do |org|
        next if org == organization

        MarketingUnsubscribe.find_or_initialize_by(organization: org, email: preference.email).update!(unsubscribed_at: Time.current)
      end
      unsubscribe_locked_platform!(preference.email, subscriber) if organization && subscriber
      preference.update!(all_unsubscribed: false)
    end
    # Explicit consent replaces the current suppression index, not the append-only
    # EmailConsent withdrawal evidence. This is not a retention purge.
    MarketingUnsubscribe.where(organization: organization, email: preference.email).delete_all if organization
  end

  def self.lock_follows!(email)
    OrganizerFollow.where(email_opted_in_address: email).order(:id).lock.load
  end

  # A follow choice can affect the current and previously verified addresses.
  # Use the same grouped calculation for GET and locked consent-only POST checks.
  def self.consent_markers(ids, email, saved_addresses: {})
    current = email.to_s.strip.downcase
    addresses = ids.to_h { |id| [id, [current, saved_addresses[id]].compact.map { |value| value.strip.downcase }.reject(&:blank?).uniq] }
    emails = addresses.values.flatten.uniq
    organizer = EmailConsent.where(email: emails, scope: "organizer", organization_id: ids).group(:organization_id, :email).maximum(:id)
    global = EmailConsent.where(email: emails, scope: "all").group(:email).maximum(:id)
    addresses.to_h do |id, affected|
      [id, affected.flat_map { |address| [organizer[[id, address]] || 0, global[address] || 0] }.max || 0]
    end
  end

  def self.unsubscribe_organizer!(organization:, email:, source:)
    email = email.to_s.strip.downcase
    with_platform_locks(email, create_preference: false) do
      lock_follows!(email).where(organization: organization).update_all(email_opted_in_at: nil)
      MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: email).update!(unsubscribed_at: Time.current)
      EmailConsent.record!(email: email, organization: organization, scope: "organizer", action: "unsubscribed", source: source)
    end
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
