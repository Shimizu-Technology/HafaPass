class Ticket < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type
  belongs_to :event
  belongs_to :pricing_tier, optional: true

  enum :status, { issued: 0, checked_in: 1, cancelled: 2, transferred: 3 }

  before_create :generate_qr_code_if_order_completed
  before_create :set_attendee_info

  validates :qr_code, uniqueness: true, allow_nil: true

  def assign_qr_code
    self.qr_code = SecureRandom.uuid
  end

  def issue_qr_code!
    return if qr_code.present?

    update!(qr_code: SecureRandom.uuid)
  end

  def check_in!
    raise "Ticket is not in issued status" unless issued?
    raise "Ticket order is not completed" unless order&.completed?

    update!(status: :checked_in, checked_in_at: Time.current)
  end

  private

  def generate_qr_code_if_order_completed
    assign_qr_code if order&.completed?
  end

  def set_attendee_info
    return if attendee_name.present? || attendee_email.present?

    self.attendee_name ||= order&.buyer_name
    self.attendee_email ||= order&.buyer_email
  end
end
