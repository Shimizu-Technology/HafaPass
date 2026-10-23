class Ticket < ApplicationRecord
  include OperationalAuditable

  audits_operations :ticket,
    fields: %w[status cancelled_at scan_credential_version display_credential_version],
    observe: %w[cancellation_reason]

  class AdmissionError < RuntimeError; end
  belongs_to :order
  belongs_to :ticket_type
  belongs_to :event
  belongs_to :pricing_tier, optional: true
  belongs_to :order_item, optional: true
  belongs_to :holder_user, class_name: "User", optional: true
  belongs_to :event_seat, optional: true
  has_many :refund_tickets, dependent: :restrict_with_error
  has_many :pending_refund_tickets, -> {
    active.joins(:refund).where(refunds: { status: Refund.statuses[:pending] })
  }, class_name: "RefundTicket"
  has_many :refunds, through: :refund_tickets
  has_many :message_deliveries, dependent: :restrict_with_error
  has_many :support_notes, dependent: :restrict_with_error
  has_many :admission_actions, dependent: :restrict_with_error
  has_many :ticket_transfers, dependent: :restrict_with_error
  has_many :wallet_passes, dependent: :restrict_with_error
  has_one :inventory_retention, class_name: "TicketInventoryRetention", dependent: :restrict_with_error

  enum :status, { issued: 0, checked_in: 1, cancelled: 2, transferred: 3 }

  before_create :generate_qr_code_if_order_completed
  before_create :set_attendee_info

  validates :qr_code, uniqueness: true, allow_nil: true
  validates :holder_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :assigned_seat_matches_ticket
  validate :preserve_retained_inventory
  validate :preserve_first_admission

  before_validation :normalize_holder
  after_update :audit_assigned_seat_cancellation, if: :assigned_seat_just_cancelled?
  after_update :refresh_wallet_passes, if: :wallet_visible_change?

  WALLET_VISIBLE_ATTRIBUTES = %w[status scan_credential_version holder_user_id attendee_name event_seat_id ticket_type_id].freeze

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
    self.class.transaction do
      increment!(:scan_credential_version)
      # increment! uses an atomic counter update and bypasses model callbacks.
      record_operational_audit!(action: "ticket.scan_credential_rotated",
        metadata: { changed_fields: ["scan_credential_version"] })
    end
    refresh_wallet_passes
  end

  def revoke_display_credential!
    self.class.transaction do
      increment!(:display_credential_version)
      record_operational_audit!(action: "ticket.display_credential_revoked",
        metadata: { changed_fields: ["display_credential_version"] })
    end
  end

  def admission_allowed?
    issued? && order.ticket_fulfilled? && !order.ticket_access_blocked? && !refund_pending? &&
      !inventory_retained? && event.published?
  end

  def refund_pending?
    order.full_refund_pending? || pending_refund_tickets.any?
  end

  def inventory_retained?
    inventory_retention.present?
  end

  def previously_admitted?
    checked_in? || first_admitted_at.present? || inventory_retained? || admission_actions.kind_admit.result_accepted.exists?
  end

  # A ticket accepted by someone other than the order's account belongs to its
  # new holder: buyer-facing views and emails must not show its details or links.
  def transferred_away_from?(order)
    holder_user_id.present? && holder_user_id != order.user_id
  end

  # The holder's own pending transfer (recipient as they typed it), so their
  # ticket list can show it and offer to cancel. Works with preloaded transfers.
  def pending_transfer_summary(at: Time.current)
    transfer = ticket_transfers.select { |item| item.active?(at: at) }.max_by(&:id)
    transfer && { id: transfer.id, recipient_email: transfer.recipient_email, expires_at: transfer.expires_at }
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

  def check_in!(credential: nil)
    order.with_lock do
      with_lock do
        raise AdmissionError, "Ticket is not in issued status" unless issued?
        raise AdmissionError, "Ticket order is not fulfilled" unless order.ticket_fulfilled?
        if order.ticket_access_blocked?
          raise AdmissionError, "Ticket access is suspended while a payment dispute is reviewed"
        end
        raise AdmissionError, "Ticket access is paused while its refund is pending" if refund_pending?
        raise AdmissionError, "Refunded or disputed admission requires organizer review" if inventory_retained?
        raise AdmissionError, "Event is #{event.status}; check-in is unavailable" unless event.reload.published?
        if credential && !TicketCredential.valid_scan_for?(self, credential)
          raise AdmissionError, "Ticket credential has been replaced"
        end

        at = Time.current
        update!(status: :checked_in, checked_in_at: at, first_admitted_at: first_admitted_at || at)
      end
    end
  end

  def reverse_check_in!
    order.with_lock do
      with_lock do
        raise AdmissionError, "Ticket is not checked in" unless checked_in?

        known_admission_at = first_admitted_at || [checked_in_at,
          admission_actions.kind_admit.result_accepted.minimum(:received_at)].compact.min
        if known_admission_at.nil? && !inventory_retained?
          raise AdmissionError, "Admission history requires organizer review before Undo"
        end
        update!(status: :issued, checked_in_at: nil, first_admitted_at: known_admission_at)
      end
    end
  end

  def release_inventory!
    raise AdmissionError, "Occupied inventory requires organizer review" if inventory_retained?

    ticket_type.with_lock do
      ticket_type.decrement!(:quantity_sold) if ticket_type.quantity_sold.positive?
    end

    pricing_tier&.with_lock do
      pricing_tier.decrement!(:quantity_sold) if pricing_tier.quantity_sold.positive?
    end
  end

  def seat_label
    event_seat&.display_label
  end

  private

  def operational_audit_action(operation)
    return unless operation == :update
    return "ticket.cancelled" if saved_change_to_status? && cancelled?
    return "ticket.scan_credential_rotated" if saved_change_to_scan_credential_version?
    "ticket.display_credential_revoked" if saved_change_to_display_credential_version?
  end

  def preserve_retained_inventory
    return unless persisted? && inventory_retained?
    if cancelled? || %w[event_seat_id ticket_type_id pricing_tier_id order_id].any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Retained occupied inventory cannot be cancelled or moved")
    end
  end

  def preserve_first_admission
    if persisted? && first_admitted_at_in_database.present? && will_save_change_to_first_admitted_at?
      errors.add(:first_admitted_at, "must preserve the original admission")
    end
  end

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

  def wallet_visible_change?
    WALLET_VISIBLE_ATTRIBUTES.any? { |attribute| saved_change_to_attribute?(attribute) }
  end

  def refresh_wallet_passes
    Wallet::PassSync.tickets_changed(id)
  end

  def assigned_seat_just_cancelled?
    event_seat_id.present? && saved_change_to_status? && cancelled?
  end

  def audit_assigned_seat_cancellation
    Seating::Audit.record!(
      event: event,
      action: "seat.released_from_ticket",
      event_seat: event_seat,
      ticket: self,
      metadata: { cancellation_reason: cancellation_reason }
    )
  end

  def assigned_seat_matches_ticket
    return unless event_seat
    unless event_seat.event_seating_configuration.event_id == event_id
      errors.add(:event_seat, "must belong to the ticket event")
    end
    errors.add(:event_seat, "must match the ticket type") unless event_seat.ticket_type_id == ticket_type_id
  end
end
