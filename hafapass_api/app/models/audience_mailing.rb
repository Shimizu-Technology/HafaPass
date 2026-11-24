# frozen_string_literal: true

class AudienceMailing < ApplicationRecord
  belongs_to :organization, optional: true
  belongs_to :created_by, class_name: "User"
  has_many :message_deliveries, dependent: :restrict_with_error
  validates :subject, :body, presence: true
  validates :subject, length: { maximum: 240 }, format: { without: /[\r\n]/ }
  validates :body, length: { maximum: 20_000 }
  validates :audience, inclusion: { in: %w[platform buyers followers waitlists] }
  validates :status, inclusion: { in: %w[draft scheduled queueing queued cancelled blocked] }
  validate { errors.add(:audience, "Invalid scope") if organization_id.nil? != (audience == "platform") }

  def authorized?
    organization ? OrganizationAuthorization.allowed?(user: created_by, organization: organization, permission: :manage_marketing) : created_by.admin?
  end

  def address
    return if !Rails.env.local? && PublicSiteUrl.api.blank?

    organization ? (organization.marketing_mailing_address if organization.marketing_postal_address_ready?) : ENV["HAFAPASS_POSTAL_ADDRESS"].presence
  end

  def sender_name
    organization&.name || "HåfaPass"
  end

  def eligible?(email)
    return false if EmailPreference.blocked?(email) || PrivacyEmailSuppression.for?(email)
    return false if MessageDelivery.new(recipient: email, channel: "email", template: "audience_mailing").suppressed_recipient?

    organization ? EmailPreferences.organizer_enabled?(organization, email) : PlatformSubscriber.find_by(email: email)&.status == "confirmed"
  end

  def audience_emails
    emails = case audience
    when "platform" then PlatformSubscriber.where(status: "confirmed").pluck(:email)
    when "buyers" then Order.joins(:event).where(events: { organization_id: organization_id }).where(status: [:completed, :partially_refunded, :refunded]).pluck(:buyer_email)
    when "followers" then OrganizerFollow.joins(:user).where(organization: organization).where.not(email_opted_in_at: nil).pluck("users.email")
    when "waitlists" then WaitlistEntry.joins(:event).where(events: { organization_id: organization_id }).where.not(status: :cancelled).pluck(:email)
    else []
    end
    emails = emails.map { |email| email.to_s.strip.downcase }.uniq.sort
    if audience == "platform"
      subscribers = PlatformSubscriber.where(email: emails, status: "confirmed")
      subscribers = subscribers.where(source: filters["source"]) if filters["source"].present?
      subscribers = subscribers.where(status: filters["status"]) if filters["status"].present?
      subscribers = subscribers.where("interests @> ?::jsonb", [filters["interest"]].to_json) if filters["interest"].present?
      subscribers = subscribers.where("created_at >= ?", Date.iso8601(filters["since"])) if filters["since"].present?
      emails = subscribers.pluck(:email)
    end
    emails.select! { |email| email.downcase.include?(filters["q"].to_s.downcase) }
    blocked = EmailPreference.where(email: emails, all_unsubscribed: true).pluck(:email)
    digests = emails.to_h { |email| [PrivacyEmailSuppression.digest(email), email] }
    blocked += PrivacyEmailSuppression.where(email_digest: digests.keys).pluck(:email_digest).map { |digest| digests.fetch(digest) }
    hard, complaints = MessageDelivery.recipient_block_history(MessageDelivery.where("LOWER(recipient) IN (?)", emails))
    blocked += hard.or(complaints).pluck(Arel.sql("LOWER(recipient)"))
    if organization
      blocked += MarketingUnsubscribe.where(organization: organization, email: emails).pluck(:email)
      confirmed = EmailConsent.where(organization: organization, email: emails, scope: "organizer")
        .select("DISTINCT ON (email) email, action").order(:email, created_at: :desc, id: :desc).filter_map { |row| row.email if row.action == "confirmed" }
      opted_orders = Order.joins(:event).where(events: { organization_id: organization_id }, status: [:completed, :partially_refunded, :refunded])
        .where("LOWER(buyer_email) IN (?)", emails).select("DISTINCT ON (LOWER(buyer_email)) orders.*")
        .order(Arel.sql("LOWER(buyer_email), orders.created_at DESC, orders.id DESC")).filter_map { |row| row.buyer_email.downcase if row.marketing_opt_in? }
      followers = OrganizerFollow.joins(:user).where(organization: organization).where.not(email_opted_in_at: nil).pluck(Arel.sql("LOWER(users.email)"))
      emails &= confirmed | opted_orders | followers
    end
    emails - blocked
  end

  def block_reason
    return "Missing mailing address or marketing permission" unless authorized? && address.present?
    return "Invalid schedule" if scheduled_at.nil?
    "Schedule expired; create and confirm a new mailing" if status == "scheduled" && scheduled_at < Integer(ENV.fetch("EMAIL_SCHEDULE_GRACE_HOURS", "6")).hours.ago
  end

  def delivery(email, test: false)
    message_deliveries.new(channel: "email", template: test ? "audience_test" : "audience_mailing",
      recipient: email, requested_by: created_by, provider: EmailService.configured? ? "resend" : "simulated",
      idempotency_key: test ? "audience-test/#{SecureRandom.uuid}" : "audience/#{id}/#{Digest::SHA256.hexdigest(email)}",
      metadata: { subject: test ? "[TEST] #{subject}" : subject, body: body, mailing_address: address, organizer_name: sender_name })
  end
end
