# frozen_string_literal: true

class MessageDelivery < ApplicationRecord
  belongs_to :order, optional: true
  belongs_to :ticket, optional: true
  belongs_to :event, optional: true
  belongs_to :communication_campaign, optional: true
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :message_provider_events, dependent: :nullify

  enum :status, {
    queued: 0, sent: 1, failed: 2, suppressed: 3, delivered: 4, delayed: 5, bounced: 6, complained: 7, cancelled: 8
  }

  validates :channel, :template, :recipient, :provider, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true, length: { maximum: 256 }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :subject_present
  validate :immutable_provider_request
  validate :consistent_wire_body

  attr_accessor :preparing_outbound_payload

  TICKET_EMAIL_TEMPLATES = %w[order_confirmation fulfillment_resend].freeze
  scope :ticket_email, -> { where(channel: "email", template: TICKET_EMAIL_TEMPLATES) }
  scope :unconfirmed_provider_result, -> {
    where(provider_outcome_unknown: true).or(
      where(provider: "resend", provider_id: [nil, ""], provider_attempted_at: nil).where("attempts > 0")
    )
  }

  PROVIDER_REPLAY_WINDOW = 23.hours

  before_validation :assign_idempotency_key, on: :create

  def ticket_email?
    channel == "email" && TICKET_EMAIL_TEMPLATES.include?(template)
  end

  def unconfirmed_provider_result?
    provider_outcome_unknown? || (provider == "resend" && provider_id.blank? &&
      provider_attempted_at.nil? && attempts.positive?)
  end

  def retryable?
    failed? && provider_id.blank? && !provider_replay_expired?
  end

  def provider_replay_expired?
    # Legacy attempted rows have no marker: a crash may have followed acceptance.
    unknown = provider_outcome_unknown? || (provider == "resend" && provider_attempted_at.nil? && attempts.positive?)
    unknown && (provider_attempted_at || created_at) <= PROVIDER_REPLAY_WINDOW.ago
  end

  def suppressed_recipient?
    history = self.class.where("LOWER(recipient) = ?", recipient.to_s.strip.downcase)
    # Local cancellation/propagated suppression is not provider evidence.
    transient_bounces = MessageProviderEvent.where(event_type: "email.bounced")
      .where("message_provider_events.message_delivery_id = message_deliveries.id")
      .where("occurred_at = message_deliveries.last_event_at")
      .where("payload #>> '{bounce,type}' = 'Transient'")
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM message_provider_events hard_bounce
          WHERE hard_bounce.message_delivery_id = message_deliveries.id
            AND hard_bounce.event_type = 'email.bounced'
            AND hard_bounce.occurred_at = message_deliveries.last_event_at
            AND COALESCE(hard_bounce.payload #>> '{bounce,type}', '') != 'Transient'
        )
      SQL
      .select(:message_delivery_id)
    hard_bounces = history.where(status: :bounced).where.not(id: transient_bounces)
    hard_bounces.or(history.where(status: :complained)).or(
      history.where(status: :suppressed).where.not(provider_id: [nil, ""])
    ).where.not(id: id).exists?
  end

  private

  def immutable_provider_request
    %w[outbound_wire_body wire_body_digest].each do |field|
      if attribute_in_database(field).present? && will_save_change_to_attribute?(field)
        errors.add(field, "cannot change after the provider wire request is prepared")
      end
    end
    if transport_context_digest_in_database.present? && will_save_change_to_transport_context_digest?
      errors.add(:transport_context_digest, "cannot change after the provider context is prepared")
    end
    return if outbound_payload_in_database.blank?

    %w[outbound_payload recipient idempotency_key].each do |field|
      errors.add(field, "cannot change after the provider request is prepared") if will_save_change_to_attribute?(field)
    end
  end

  def consistent_wire_body
    return if outbound_wire_body.nil? && wire_body_digest.nil?

    unless outbound_wire_body.present? && wire_body_digest == Digest::SHA256.hexdigest(outbound_wire_body) &&
        JSON.parse(outbound_wire_body) == outbound_payload
      errors.add(:outbound_wire_body, "must match the frozen payload and wire digest")
    end
  rescue JSON::ParserError
    errors.add(:outbound_wire_body, "must be valid JSON")
  end

  def subject_present
    errors.add(:base, "Order, ticket, or event is required") if order_id.blank? && ticket_id.blank? && event_id.blank?
  end

  def assign_idempotency_key
    self.idempotency_key ||= "message/#{SecureRandom.uuid}"
  end
end
