class WaitlistEntry < ApplicationRecord
  belongs_to :event
  belongs_to :ticket_type, optional: true
  belongs_to :user, optional: true
  has_many :waitlist_offers, dependent: :restrict_with_error

  enum :status, { waiting: 0, notified: 1, offered: 2, converted: 3, expired: 4, cancelled: 5 }

  validates :locale, inclusion: { in: AppLocale::SUPPORTED }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :quantity, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
  validates :position, presence: true
  validates :email, uniqueness: { scope: [:event_id, :ticket_type_id], message: "is already on the waitlist for this ticket type" }

  before_validation :assign_position, on: :create
  before_validation :record_request_time, on: :create

  scope :active, -> { where(status: [:waiting, :notified, :offered]) }
  scope :by_position, -> { order(:position) }

  def active?
    waiting? || notified? || offered?
  end

  def notify!
    WaitlistDelivery.ensure_address!(event)
    update!(
      status: :notified,
      notified_at: Time.current,
      expires_at: 24.hours.from_now,
      delivery_failure: nil
    )
  end

  def notify_and_queue!
    with_lock do
      return false unless waiting?

      # A late provider receipt can turn a previously failed round into a
      # delivered one. Never create another round for that buyer.
      if notified_at.present? && MessageDelivery.exists?(
          template: "waitlist_notification", status: :delivered,
          idempotency_key: "waitlist-notification/#{id}/#{notified_at.iso8601(6)}")
        update!(status: :notified, expires_at: 24.hours.from_now, delivery_failure: nil)
        return false
      end

      notify!
      EmailService.send_waitlist_notification_async(self)
      true
    end
  end

  def retry_unconfirmed_notification!
    with_lock do
      return false unless notified? && delivery_failure == WaitlistDelivery::UNCONFIRMED
      return false if MessageDelivery.exists?(template: "waitlist_notification", status: :delivered,
        idempotency_key: "waitlist-notification/#{id}/#{notified_at.iso8601(6)}")

      notify!
      EmailService.send_waitlist_notification_async(self)
      true
    end
  end

  def offer_expired?
    expires_at.present? && expires_at < Time.current && !converted?
  end

  def management_credential
    WaitlistCredential.management(self)
  end

  private

  def record_request_time
    self.requested_at ||= Time.current
  end

  def assign_position
    return if position.present?

    # Use advisory lock to prevent race conditions on position assignment
    self.position = (self.class
      .where(event_id: event_id, ticket_type_id: ticket_type_id)
      .maximum(:position) || 0) + 1
  end
end
