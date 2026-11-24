# frozen_string_literal: true

class AudienceMailing < ApplicationRecord
  belongs_to :organization, optional: true
  belongs_to :created_by, class_name: "User"
  has_many :message_deliveries, dependent: :restrict_with_error
  validates :subject, :body, presence: true
  validates :subject, length: { maximum: 240 }, format: { without: /[\r\n]/ }
  validates :body, length: { maximum: 20_000 }
  validates :audience, inclusion: { in: %w[platform buyers followers waitlists] }
  validates :status, inclusion: { in: %w[draft scheduled queueing queued] }
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
    emails.map { |email| email.to_s.strip.downcase }.uniq.sort.select { |email| eligible?(email) }
  end

  def delivery(email, test: false)
    message_deliveries.new(channel: "email", template: test ? "audience_test" : "audience_mailing",
      recipient: email, requested_by: created_by, provider: EmailService.configured? ? "resend" : "simulated",
      idempotency_key: test ? "audience-test/#{SecureRandom.uuid}" : "audience/#{id}/#{Digest::SHA256.hexdigest(email)}",
      metadata: { subject: test ? "[TEST] #{subject}" : subject, body: body, mailing_address: address, organizer_name: sender_name })
  end
end
