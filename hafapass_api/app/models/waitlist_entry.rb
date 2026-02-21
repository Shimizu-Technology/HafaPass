class WaitlistEntry < ApplicationRecord
  belongs_to :event
  belongs_to :ticket_type, optional: true
  belongs_to :user, optional: true

  enum :status, { waiting: 0, notified: 1, offered: 2, converted: 3, expired: 4, cancelled: 5 }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :quantity, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
  validates :position, presence: true
  validates :email, uniqueness: { scope: [:event_id, :ticket_type_id], message: "is already on the waitlist for this ticket type" }

  before_validation :assign_position, on: :create

  scope :active, -> { where(status: [:waiting, :notified, :offered]) }
  scope :by_position, -> { order(:position) }

  def notify!
    update!(
      status: :notified,
      notified_at: Time.current,
      expires_at: 24.hours.from_now
    )
  end

  def offer_expired?
    expires_at.present? && expires_at < Time.current && !converted?
  end

  private

  def assign_position
    return if position.present?

    # Use advisory lock to prevent race conditions on position assignment
    self.position = (self.class
      .where(event_id: event_id, ticket_type_id: ticket_type_id)
      .maximum(:position) || 0) + 1
  end
end
