class Ticket < ApplicationRecord
  include OperationalAuditable
  include PublicEventCacheBuster

  # Cancelling or refunding a ticket returns its inventory (or pass night capacity).
  busts_public_event_cache on: :update, condition: -> { saved_change_to_status? && cancelled? }

  audits_operations :ticket,
    fields: %w[status cancelled_at scan_credential_version display_credential_version],
    observe: %w[cancellation_reason]

  class AdmissionError < RuntimeError; end
  belongs_to :order
  belongs_to :ticket_type
  belongs_to :event
  belongs_to :pricing_tier, optional: true
  belongs_to :order_item, optional: true
  belongs_to :parent_ticket, class_name: "Ticket", optional: true
  belongs_to :holder_user, class_name: "User", optional: true
  belongs_to :event_seat, optional: true
  belongs_to :last_entry_device, class_name: "ScannerDevice", optional: true
  has_many :child_tickets, class_name: "Ticket", foreign_key: :parent_ticket_id, dependent: :restrict_with_error
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
  has_many :registration_responses, dependent: :restrict_with_error
  has_one :inventory_retention, class_name: "TicketInventoryRetention", dependent: :restrict_with_error

  enum :status, { issued: 0, checked_in: 1, cancelled: 2, transferred: 3 }
  OCCUPANCY_STATES = %w[outside inside].freeze

  scope :scannable, -> {
    where.not(parent_ticket_id: nil, ticket_type_id: TicketType.where(is_pass: true).select(:id))
  }

  before_create :generate_qr_code_if_order_completed
  before_create :set_attendee_info

  validates :qr_code, uniqueness: true, allow_nil: true
  validates :holder_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :occupancy_state, inclusion: { in: OCCUPANCY_STATES }
  validates :re_entry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
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
    with_entry_lock do
      increment!(:scan_credential_version)
      # increment! uses an atomic counter update and bypasses model callbacks.
      record_operational_audit!(action: "ticket.scan_credential_rotated",
        metadata: { changed_fields: ["scan_credential_version"] })
    end
    refresh_wallet_passes
  end

  def revoke_display_credential!
    with_entry_lock do
      increment!(:display_credential_version)
      record_operational_audit!(action: "ticket.display_credential_revoked",
        metadata: { changed_fields: ["display_credential_version"] })
    end
  end

  def pass_child?
    parent_ticket_id.present?
  end

  def pass_parent?
    parent_ticket_id.nil? && ticket_type.is_pass?
  end

  # The order-wide answers plus the answers given for this ticket. A pass
  # night ticket uses the answers recorded on its pass. Reads the order's
  # loaded responses, so preloading order: :registration_responses avoids N+1.
  def effective_registration_responses
    answered_ticket_id = parent_ticket_id || id
    order.registration_responses.select { |response| response.ticket_id.nil? || response.ticket_id == answered_ticket_id }
  end

  def admission_block_reason(payment_mode: nil, allow_checked_in: false)
    return "pass_container" if pass_parent?
    return "cancelled" if cancelled? || (pass_child? && parent_ticket&.cancelled?)
    return "transferred" if transferred?
    return "inventory_retained" if inventory_retained? || (pass_child? && parent_ticket&.inventory_retained?)
    return "payment_blocked" if order.ticket_access_blocked?
    return "refund_pending" if refund_pending?
    return "unfulfilled" unless order.ticket_fulfilled?(payment_mode: payment_mode)
    return "event_unavailable" unless event.published?
    return "not_admissible" unless issued? || (allow_checked_in && checked_in?)

    nil
  end

  def admission_allowed?(payment_mode: nil)
    admission_block_reason(payment_mode: payment_mode).nil?
  end

  def entered_on_day?(day)
    checked_in? && occupancy_day.present? && occupancy_day == day
  end

  def effective_occupancy_state(day:)
    entered_on_day?(day) ? occupancy_state : "outside"
  end

  def effective_re_entry_count(day:)
    entered_on_day?(day) ? re_entry_count : 0
  end

  def refund_pending?
    order.full_refund_pending? || pending_refund_tickets.any? ||
      (parent_ticket&.pending_refund_tickets&.any? || false)
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

  # Include the audit's implicit organization FK lock in the mutation prefix.
  # Callers must enter here before owning an order, ticket or transfer lock.
  # Reconciliation already owns these parents; reacquiring them is harmless.
  def with_entry_lock(actor: nil)
    self.class.transaction do
      actor&.lock!("FOR NO KEY UPDATE")
      # Serialize authority changes, but allow event-first commerce to insert
      # an organization audit FK while we wait for its event lock.
      event.organization.lock!("FOR NO KEY UPDATE")
      event.lock!
      order.with_lock do
        with_lock { yield }
      end
    end
  end

  def refundable_cents
    return 0 unless order_item

    tickets = order_item.tickets.order(:id).pluck(:id)
    allocation = Commerce::MoneyAllocator.call(order_item_total_cents, Array.new(tickets.length, 1))
    allocation[tickets.index(id)] || 0
  end

  def check_in!(credential: nil, actor: nil, occurred_at: nil, device: nil)
    with_entry_lock(actor: actor) do
      if actor && !OrganizationAuthorization.allowed?(user: actor, organization: event.organization,
          permission: :scan, event: event)
        raise AdmissionError, "Scanner assignment is no longer active"
      end
      event.reload
      association(:parent_ticket).reset if pass_child?
      if (block_reason = admission_block_reason)
        raise AdmissionError, admission_error_message(block_reason)
      end
      if credential && !TicketCredential.valid_scan_for?(self, credential)
        raise AdmissionError, "Ticket credential has been replaced"
      end

      at = Time.current
      entry_at = occurred_at || at
      update!(
        status: :checked_in,
        checked_in_at: at,
        first_admitted_at: first_admitted_at || at,
        occupancy_state: "inside",
        occupancy_day: event.occupancy_day_for(entry_at),
        last_entry_at: entry_at,
        last_entry_device: device || last_entry_device,
        re_entry_count: 0,
        re_entry_conflict_flagged: false
      )
    end
  end

  # Caller holds the ticket entry lock and has validated re-entry eligibility.
  def record_re_entry!(occurred_at:, device: nil, day: nil, clear_conflict: false)
    target_day = day || event.occupancy_day_for(occurred_at)
    same_day = entered_on_day?(target_day)
    next_count = same_day ? re_entry_count + 1 : 0
    at = Time.current
    update!(
      status: :checked_in,
      checked_in_at: checked_in_at || at,
      first_admitted_at: first_admitted_at || at,
      occupancy_state: "inside",
      occupancy_day: target_day,
      last_entry_at: occurred_at,
      last_entry_device: device,
      re_entry_count: next_count,
      re_entry_conflict_flagged: clear_conflict ? false : re_entry_conflict_flagged
    )
  end

  # Caller holds the ticket entry lock and has validated exit eligibility.
  def record_exit!(occurred_at:, day: nil, clear_conflict: false)
    target_day = day || event.occupancy_day_for(occurred_at)
    update!(
      occupancy_state: "outside",
      occupancy_day: target_day,
      last_exit_at: occurred_at,
      re_entry_conflict_flagged: clear_conflict ? false : re_entry_conflict_flagged
    )
  end

  def reverse_check_in!
    with_entry_lock do
      raise AdmissionError, "Ticket is not checked in" unless checked_in?

      known_admission_at = first_admitted_at || [checked_in_at,
        admission_actions.kind_admit.result_accepted.minimum(:received_at)].compact.min
      if known_admission_at.nil? && !inventory_retained?
        raise AdmissionError, "Admission history requires organizer review before Undo"
      end
      update!(
        status: :issued,
        checked_in_at: nil,
        first_admitted_at: known_admission_at,
        occupancy_state: "outside",
        occupancy_day: nil,
        last_entry_at: nil,
        last_exit_at: nil,
        last_entry_device_id: nil,
        re_entry_count: 0,
        re_entry_conflict_flagged: false
      )
    end
  end

  def release_inventory!
    return if pass_child?
    raise AdmissionError, "Occupied inventory requires organizer review" if inventory_retained?

    ticket_type.with_lock do
      ticket_type.decrement!(:quantity_sold) if ticket_type.quantity_sold.positive?
    end

    pricing_tier&.with_lock do
      pricing_tier.decrement!(:quantity_sold) if pricing_tier.quantity_sold.positive?
    end
  end

  # The caller holds the order and ticket locks and has checked admission.
  def cancel_unused_and_release_inventory!(reason:)
    release_inventory!
    update!(status: :cancelled, cancelled_at: Time.current, cancellation_reason: reason,
      scan_credential_version: scan_credential_version + 1)
  end

  def seat_label
    event_seat&.display_label
  end

  private

  def admission_error_message(block_reason)
    case block_reason
    when "pass_container"
      "Multi-night pass containers cannot be scanned directly; scan the ticket for tonight's event"
    when "cancelled", "transferred", "not_admissible"
      "Ticket is not in issued status"
    when "unfulfilled"
      "Ticket order is not fulfilled"
    when "payment_blocked"
      "Ticket access is suspended while a payment dispute is reviewed"
    when "refund_pending"
      "Ticket access is paused while its refund is pending"
    when "inventory_retained"
      "Refunded or disputed admission requires organizer review"
    when "event_unavailable"
      "Event is #{event.status}; check-in is unavailable"
    else
      "Ticket is not eligible for admission"
    end
  end

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
