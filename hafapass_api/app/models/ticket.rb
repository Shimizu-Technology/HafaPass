class Ticket < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type
  belongs_to :event
  belongs_to :pricing_tier, optional: true
  belongs_to :order_item, optional: true
  belongs_to :holder_user, class_name: "User", optional: true
  has_many :refund_tickets, dependent: :restrict_with_error
  has_many :refunds, through: :refund_tickets
  has_many :message_deliveries, dependent: :restrict_with_error
  has_many :support_notes, dependent: :restrict_with_error
  has_many :admission_actions, dependent: :restrict_with_error
  has_many :ticket_transfers, dependent: :restrict_with_error

  enum :status, { issued: 0, checked_in: 1, cancelled: 2, transferred: 3 }

  before_create :generate_qr_code_if_order_completed
  before_create :set_attendee_info

  validates :qr_code, uniqueness: true, allow_nil: true
  validates :holder_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  before_validation :normalize_holder

  def issue_qr_code!
    return if qr_code.present?

    update!(qr_code: SecureRandom.uuid)
  end

  def display_credential
    TicketCredential.display(self)
  end

  def scan_credential
    TicketCredential.scan(self)
  end

  def rotate_scan_credential!
    increment!(:scan_credential_version)
  end

  def revoke_display_credential!
    increment!(:display_credential_version)
  end

  def admission_allowed?
    issued? && order.ticket_fulfilled? && !order.ticket_access_blocked? && event.published?
  end

  def held_by?(user)
    user.present? && holder_user_id == user.id
  end

  def refundable_cents
    return 0 unless order_item

    tickets = order_item.tickets.order(:id).pluck(:id)
    allocation = Commerce::MoneyAllocator.call(order_item_total_cents, Array.new(tickets.length, 1))
    allocation[tickets.index(id)] || 0
  end

  def check_in!
    raise "Ticket is not in issued status" unless issued?
    raise "Ticket order is not fulfilled" unless order&.ticket_fulfilled?

    update!(status: :checked_in, checked_in_at: Time.current)
  end

  def reverse_check_in!
    raise "Ticket is not checked in" unless checked_in?

    update!(status: :issued, checked_in_at: nil)
  end

  def release_inventory!
    ticket_type.with_lock do
      ticket_type.decrement!(:quantity_sold) if ticket_type.quantity_sold.positive?
    end

    pricing_tier&.with_lock do
      pricing_tier.decrement!(:quantity_sold) if pricing_tier.quantity_sold.positive?
    end
  end

  private

  def order_item_total_cents
    order_item.subtotal_cents + order_item.fee_cents + order_item.tax_cents - order_item.discount_cents
  end

  def assign_qr_code
    self.qr_code = SecureRandom.uuid
  end

  def generate_qr_code_if_order_completed
    assign_qr_code if order&.completed?
  end

  def set_attendee_info
    unless attendee_name.present? || attendee_email.present?
      self.attendee_name ||= order&.buyer_name
      self.attendee_email ||= order&.buyer_email
    end
    self.holder_user ||= order&.user
    self.holder_email ||= attendee_email || order&.buyer_email
  end

  def normalize_holder
    self.holder_email = holder_email.to_s.strip.downcase.presence
  end
end
