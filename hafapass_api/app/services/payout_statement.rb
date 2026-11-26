# frozen_string_literal: true

# The organizer's plain-language payout statement for one event.
#
# Every money line is a regrouping of the settlement calculator's own items
# (the same rows a finalized version stores and digests), and every total comes
# from the calculator's attributes. Nothing here recalculates fees, refunds or
# reserves. `reconciles` is true only when the lines add up to the totals; a
# spec holds it true, and the page shows a warning if it ever is not.
#
# With a payout, the statement also describes that transfer and the frozen
# statement version it was paid from.
class PayoutStatement
  CASH_KINDS = OrganizationFinanceSummary::CASH_CUSTODY_KINDS
  STATUSES = {
    "sales_open" => "Sales open",
    "waiting_for_payout" => "Waiting for payout",
    "reserve_held" => "Paid — reserve held until %<date>s",
    "final" => "Final"
  }.freeze
  TRANSFER_STATUSES = %w[pending processing held paid reversed].freeze

  def self.call(**)
    new(**).call
  end

  def initialize(event:, payout: nil, at: Time.current)
    @event = event
    @payout = payout
    @at = at
  end

  def call
    {
      event: event_json,
      organization: { id: event.organization_id, name: event.organization.name },
      currency: event.organization.currency.upcase,
      generated_at: at,
      status: status,
      status_label: status_label,
      schedule: schedule_json,
      sales_by_ticket: sales_by_ticket,
      sections: sections,
      totals: totals,
      closing: closing,
      reconciles: difference_cents.zero? && contradictions.empty?,
      difference_cents: difference_cents,
      contradictions: contradictions,
      notes: notes,
      transfers: transfers,
      payout: payout && payout_json(payout).merge(version: version_json(payout.settlement))
    }
  end

  # Spreadsheet rows: section, line, amount in cents (nil for text), note.
  def csv_rows
    data = call
    rows = [
      ["Statement", "Event", nil, event.title],
      ["Statement", "Organization", nil, event.organization.name],
      ["Statement", "Status", nil, data[:status_label]],
      ["Statement", "Generated", nil, at.in_time_zone(PayoutCalendar.timezone_for(event)).iso8601]
    ]
    data[:sales_by_ticket].each do |row|
      rows << ["Ticket sales", "#{row[:name]} (#{row[:quantity]} sold)", row[:gross_cents], nil]
    end
    data[:sections].each do |section|
      section[:lines].each { |line| rows << [section[:title], line[:label], line[:amount_cents], line[:note]] }
      rows << [section[:title], section[:total_label], section[:total_cents], nil] if section[:total_label]
    end
    data[:transfers].each do |transfer|
      rows << ["Transfers", transfer_label(transfer), transfer[:counted_cents], transfer[:status_label]]
    end
    data[:closing][:lines].each { |line| rows << ["Balance", line[:label], line[:amount_cents], line[:note]] }
    rows << ["Balance", data[:closing][:total_label], data[:closing][:total_cents], nil]
    data[:notes].each { |note| rows << ["Notes", note, nil, nil] }
    rows
  end

  private

  attr_reader :event, :payout, :at

  def schedule
    @schedule ||= PayoutSchedule.for(event, at: at, result: result)
  end

  def result
    @result ||= Settlements::Calculator.call(event)
  end

  def attributes
    result.attributes
  end

  def items
    result.items
  end

  def items_of(kind)
    items.select { |item| item[:kind] == kind }
  end

  def metadata(item)
    item[:metadata].to_h.with_indifferent_access
  end

  def sum(list)
    list.sum { |item| item[:amount_cents] }
  end

  def event_json
    {
      id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      starts_at: event.starts_at,
      ends_at: schedule.ended_at,
      timezone: PayoutCalendar.timezone_for(event).tzinfo.name,
      multi_day: event.ticket_types.where(is_pass: true).exists?
    }
  end

  # --- Status -------------------------------------------------------------

  def status
    @status ||= if !schedule.ended?
      "sales_open"
    elsif schedule.in_flight_cents.positive? || schedule.owed_cents.positive?
      "waiting_for_payout"
    elsif schedule.reserve_held_cents.positive?
      schedule.first_transfer_sent? ? "reserve_held" : "waiting_for_payout"
    else
      "final"
    end
  end

  def status_label
    format(STATUSES.fetch(status), date: schedule.reserve_release_on&.strftime("%b %-d, %Y"))
  end

  def schedule_json
    {
      ended: schedule.ended?,
      ended_on: schedule.end_date,
      transfer_expected_by: schedule.transfer_due_on,
      reserve_release_on: schedule.reserve_release_on,
      reserve_released: schedule.reserve_released_cents.positive?
    }
  end

  # --- Sales by ticket ----------------------------------------------------

  def sale_items
    @sale_items ||= items_of("sale_proceeds")
  end

  def order_items
    @order_items ||= OrderItem.where(id: sale_items.map { |item| item[:source_id] }).index_by(&:id)
  end

  def sales_by_ticket
    @sales_by_ticket ||= sale_items.group_by { |item| ticket_label(order_items[item[:source_id]]) }.map do |name, group|
      {
        name: name,
        quantity: group.sum { |item| order_items[item[:source_id]]&.quantity.to_i },
        gross_cents: group.sum { |item| metadata(item)[:subtotal_cents].to_i },
        discount_cents: group.sum { |item| metadata(item)[:discount_cents].to_i },
        proceeds_cents: sum(group)
      }
    end.sort_by { |row| [-row[:gross_cents], row[:name]] }
  end

  def ticket_label(order_item)
    return "Other" unless order_item

    [order_item.name, order_item.tier_name].compact_blank.uniq.join(" — ")
  end

  # --- Sections -----------------------------------------------------------

  def gross_cents = sales_by_ticket.sum { |row| row[:gross_cents] }
  def discount_cents = sales_by_ticket.sum { |row| row[:discount_cents] }
  def sale_proceeds_cents = sum(sale_items)
  # The HåfaPass fee share the organizer chose to cover, by line: whatever
  # separates a line's price after discount from its proceeds.
  def organizer_fee_cents = gross_cents - discount_cents - sale_proceeds_cents
  def refund_items = items_of("refund")
  def refunded_proceeds_cents = -sum(refund_items)
  def processing_cents = -sum(items_of("processing_fee"))
  def dispute_cents = -sum(items_of("dispute"))

  def adjustment_items
    items_of("adjustment")
  end

  def cash_items
    adjustment_items.select { |item| CASH_KINDS.include?(metadata(item)[:adjustment_kind]) }
  end

  def other_adjustment_items
    adjustment_items - cash_items - never_fulfilled_items - linked_adjustment_items
  end

  # The $0 "Payment received, order unfulfilled" lines (design §8.3).
  def never_fulfilled_items
    @never_fulfilled_items ||= adjustment_items.select do |item|
      metadata(item)[:adjustment_kind] == Commerce::ClassifiedOrganizerView::INFO_ADJUSTMENT_KIND
    end
  end

  # Adjustments linked to a payment returned to the buyer: shown at $0, as
  # the calculator counts them, with the reason finance recorded.
  def linked_adjustment_items
    @linked_adjustment_items ||= adjustment_items.select { |item| metadata(item)[:never_fulfilled_linked] }
  end

  # Live return status for each $0 line, read from the buyer ledger now. It
  # is never part of the stored statement or its digest.
  def never_fulfilled_lines
    @never_fulfilled_lines ||= begin
      captures = UnfulfilledCapture.where(payment_id: never_fulfilled_items.flat_map { |item| metadata(item)[:payment_ids] })
        .to_a.index_by(&:payment_id)
      never_fulfilled_items.map do |item|
        status = Commerce::ClassifiedOrganizerView.return_status(captures.values_at(*metadata(item)[:payment_ids]).compact)
        line(item[:description], item[:amount_cents], "#{status[:label]}. Not part of your proceeds.")
          .merge(return_status: status[:status])
      end
    end
  end

  def door_cash_cents = -sum(cash_items)

  def reserve_items
    items_of("reserve")
  end

  def reserve_holds_cents = -sum(reserve_items.select { |item| metadata(item)[:adjustment_kind] == "reserve_hold" })
  def reserve_releases_cents = sum(reserve_items.select { |item| metadata(item)[:adjustment_kind] == "reserve_release" })

  def sections
    [proceeds_section, deductions_section, reserve_section]
  end

  def proceeds_section
    lines = [
      line("Ticket sales", gross_cents, "Face value of every ticket and add-on sold, before discounts."),
      (line("Discounts and promo codes", -discount_cents) if discount_cents.positive?),
      (line("HåfaPass fees you covered", -organizer_fee_cents,
        "On tickets where you chose to pay the HåfaPass fee instead of the buyer.") if organizer_fee_cents.nonzero?),
      (line("Refunds", -refunded_proceeds_cents, refund_note) if refund_items.any?),
      *never_fulfilled_lines
    ].compact
    { key: "proceeds", title: "Ticket sales", lines: lines, total_label: "Your ticket proceeds",
      total_cents: lines.sum { |entry| entry[:amount_cents] } }
  end

  def deductions_section
    lines = [
      (line("Card processing", -processing_cents, processing_note) if processing_cents.nonzero?),
      (line("Door cash you collected", -door_cash_cents,
        "You already have this cash, so it is not part of the bank transfer.") if cash_items.any?),
      (line("Chargebacks", -dispute_cents,
        "Card payments a buyer's bank took back after a dispute was lost.") if dispute_cents.nonzero?),
      *other_adjustment_items.map { |item| line(adjustment_label(item), item[:amount_cents], item[:description]) },
      *linked_adjustment_items.map do |item|
        line("Adjustment on a payment returned to a buyer (not counted)", item[:amount_cents], item[:description])
      end
    ].compact
    { key: "deductions", title: "Costs and adjustments", lines: lines, total_label: "Net proceeds",
      total_cents: proceeds_section[:total_cents] + lines.sum { |entry| entry[:amount_cents] } }
  end

  def reserve_section
    lines = []
    if reserve_holds_cents.positive?
      lines << line("Reserve held", -reserve_holds_cents, reserve_hold_note)
    end
    lines << line("Reserve released", reserve_releases_cents, reserve_release_note) if reserve_releases_cents.positive?
    { key: "reserve", title: "Chargeback reserve", lines: lines, total_label: "Total to be sent to you",
      total_cents: deductions_section[:total_cents] + lines.sum { |entry| entry[:amount_cents] } }
  end

  def line(label, amount_cents, note = nil)
    { label: label, amount_cents: amount_cents, note: note }
  end

  def refund_note
    to_buyers = refund_items.sum { |item| metadata(item)[:buyer_refund_cents].to_i }
    "Your share of refunds. Buyers got back #{money(to_buyers)} in total, including fees returned to them."
  end

  def processing_note
    covered = attributes[:platform_processing_fee_cents]
    base = "Stripe's card processing cost on orders where it comes out of your proceeds."
    covered.positive? ? "#{base} HåfaPass covered #{money(covered)} more on your ticket sales." : base
  end

  def adjustment_label(item)
    case metadata(item)[:adjustment_kind]
    when "manual_credit", "dispute_recovery" then "Credit"
    when "manual_debit", "dispute_loss" then "Debit"
    when "payout_reversal" then "Returned transfer"
    else item[:amount_cents].negative? ? "Debit" : "Credit"
    end
  end

  def reserve_hold_note
    net = schedule.custodial_net_cents
    percent = net.positive? ? " (about #{((reserve_holds_cents * 100.0) / net).round}% of the net proceeds HåfaPass holds for you)" : ""
    release = schedule.reserve_release_on
    "Held back for #{PayoutSchedule::RESERVE_DAYS} days in case of chargebacks#{percent}." +
      (release ? " Release date: #{release.strftime("%b %-d, %Y")}." : "")
  end

  def reserve_release_note
    if dispute_cents.positive?
      "The reserve came back to you. Chargebacks above were taken from it before it was sent."
    else
      "The reserve came back to you after #{PayoutSchedule::RESERVE_DAYS} days."
    end
  end

  # --- Transfers and totals ----------------------------------------------

  def transfer_payouts
    @transfer_payouts ||= event.payouts.where(status: TRANSFER_STATUSES).order(:created_at, :id).to_a
  end

  def transfers
    transfer_payouts.map do |record|
      counted = %w[paid pending processing held].include?(record.status) ? -record.amount_cents : 0
      payout_json(record).merge(counted_cents: counted)
    end
  end

  def payout_json(record)
    paid = record.status_paid?
    {
      id: record.id,
      status: record.status,
      status_label: transfer_status_label(record),
      # Money has left only for a paid payout, or one in flight with a real
      # provider or bank reference. The manual gateway's placeholder means
      # finance has not sent the bank transfer yet.
      dispatched: record.status_paid? || (record.status_processing? && !PayoutEntryGuard.placeholder?(record.provider_payout_id)),
      method: record.provider == "check" ? "check" : "bank_transfer",
      amount_cents: record.amount_cents,
      withheld_cents: record.withheld_cents,
      sent_cents: record.disbursement_cents,
      requested_on: PayoutCalendar.local_date(record.created_at, event),
      sent_on: paid ? PayoutCalendar.local_date(record.paid_at || record.updated_at, event) : nil,
      bank_last4: bank_last4(record),
      reference: paid ? record.provider_payout_id : nil,
      statement_version: record.settlement&.version
    }
  end

  # The frozen statement version a transfer was paid from: what was owed when
  # finance approved it.
  def version_json(settlement)
    return unless settlement

    values = settlement.attributes.symbolize_keys
    {
      version: settlement.version,
      finalized_at: settlement.finalized_at,
      net_proceeds_cents: PayoutSchedule.net_before_reserve_cents(values),
      reserve_held_cents: settlement.reserve_cents,
      available_cents: PayoutSchedule.balance_before_payout_cents(values),
      previously_sent_cents: settlement.paid_cents
    }
  end

  def transfer_status_label(record)
    return "Approved, not sent yet" if record.status_processing? && PayoutEntryGuard.placeholder?(record.provider_payout_id)

    {
      "paid" => "Sent",
      "pending" => "Being prepared",
      "processing" => "Being sent",
      "held" => "On hold",
      "reversed" => "Returned"
    }.fetch(record.status, record.status.humanize)
  end

  def transfer_label(transfer)
    parts = [transfer[:method] == "check" ? "Check" : "Bank transfer"]
    parts << "to account ending #{transfer[:bank_last4]}" if transfer[:bank_last4]
    parts << "on #{transfer[:sent_on].iso8601}" if transfer[:sent_on]
    parts << "ref #{transfer[:reference]}" if transfer[:reference]
    parts.join(" ")
  end

  # Only the last four digits from the approved payee snapshot; the masked
  # value never holds more than that.
  def bank_last4(record)
    record.payee_snapshot.to_h["masked_account"].to_s.scan(/\d/).last(4).join.presence
  end

  def transferred_cents = transfer_payouts.select(&:status_paid?).sum(&:amount_cents)
  def in_progress_cents = transfer_payouts.select { |record| %w[pending processing held].include?(record.status) }.sum(&:amount_cents)

  def totals
    @totals ||= {
      gross_cents: gross_cents,
      ticket_proceeds_cents: proceeds_section[:total_cents],
      net_proceeds_cents: schedule.net_before_reserve_cents,
      reserve_held_cents: schedule.reserve_held_cents,
      reserve_released_cents: reserve_releases_cents,
      available_cents: schedule.balance_before_payout_cents,
      transferred_cents: transferred_cents,
      in_progress_cents: in_progress_cents,
      balance_remaining_cents: schedule.balance_before_payout_cents - transferred_cents - in_progress_cents,
      # What the organizer can still expect, counting the reserve that comes
      # back after 30 days. Negative means they owe it.
      still_to_come_cents: schedule.balance_before_payout_cents - transferred_cents - in_progress_cents +
        schedule.reserve_held_cents,
      buyer_paid_fees_cents: buyer_paid_fees_cents,
      processing_covered_by_hafapass_cents: attributes[:platform_processing_fee_cents],
      door_cash_cents: door_cash_cents
    }
  end

  # After the transfers: when a reserve is still held, show the balance
  # without it and the reserve itself, so "you owe" is only ever said about
  # money the reserve does not cover.
  def closing
    @closing ||= begin
      lines = []
      if totals[:reserve_held_cents].positive?
        lines << line("Balance after transfers, not counting the reserve", totals[:balance_remaining_cents])
        lines << line("Reserve still held", totals[:reserve_held_cents], reserve_still_held_note)
      end
      still = totals[:still_to_come_cents]
      { lines: lines, total_label: still.negative? ? "You owe" : "Still to come", total_cents: still }
    end
  end

  def reserve_still_held_note
    release = schedule.reserve_release_on
    "Comes back to you#{release ? " on #{release.strftime("%b %-d, %Y")}" : ""}, less any later refunds or chargebacks."
  end

  # Statements that add up can still say contradictory things. Each entry
  # names one; any entry makes reconciles false and the page warns.
  def contradictions
    @contradictions ||= begin
      found = []
      closing_sum = reserve_section[:total_cents] + transfers.sum { |transfer| transfer[:counted_cents] } +
        totals[:reserve_held_cents]
      found << "closing_total" unless closing_sum == closing[:total_cents] && closing[:total_cents] == totals[:still_to_come_cents]
      found << "final_with_money_pending" if status == "final" && (totals[:reserve_held_cents].positive? ||
        totals[:in_progress_cents].positive? || totals[:still_to_come_cents].positive?)
      found << "reserve_status_without_reserve" if status == "reserve_held" && !totals[:reserve_held_cents].positive?
      owes = notes.any? { |note| note.include?("you owe") }
      found << "owe_note_mismatch" if owes != totals[:still_to_come_cents].negative?
      found
    end
  end

  # The settlement's own totals, compared with the statement's lines: the
  # statement's last section total must equal the calculator's balance, and
  # its first section must equal organizer proceeds.
  def difference_cents
    @difference_cents ||= (reserve_section[:total_cents] - schedule.balance_before_payout_cents).abs +
      (proceeds_section[:total_cents] - attributes[:organizer_proceeds_cents]).abs
  end

  # Fees buyers paid on top of the ticket price. Informational: it never was
  # the organizer's money.
  def buyer_paid_fees_cents
    sold = order_items.values.sum(&:fee_cents)
    refunded = RefundItem.where(id: refund_items.map { |item| item[:source_id] }).sum(:fee_cents)
    sold - refunded
  end

  def notes
    return @notes if @notes

    notes = []
    notes << "Buyers paid #{money(buyer_paid_fees_cents)} in HåfaPass fees on top of ticket prices. That was never part of your proceeds." if buyer_paid_fees_cents.positive?
    if never_fulfilled_items.any?
      notes << "A payment that arrived after its order was released is the buyer's money. HåfaPass returns it to " \
        "the buyer, and it is never part of your proceeds or payout."
    end
    if door_cash_cents.positive?
      notes << "Door cash (#{money(door_cash_cents)}) stays with you and is not included in any bank transfer."
    end
    direct = schedule.organizer_direct_card_cents
    if direct.positive? && (reserve_holds_cents.positive? || schedule.suggested_reserve_cents.positive?)
      notes << "Card sales on your own terminal (#{money(direct)}) are paid to you by your card processor, " \
        "so no chargeback reserve is held on them."
    end
    if status == "waiting_for_payout" && schedule.transfer_due_on && !schedule.first_transfer_sent?
      notes << "HåfaPass sends the bank transfer within 2–3 business days after the event (by #{schedule.transfer_due_on.strftime("%b %-d, %Y")})."
    end
    still = totals[:still_to_come_cents]
    held = totals[:reserve_held_cents]
    if still.negative?
      covered = held.positive? ? ", even after your #{money(held)} reserve" : ""
      notes << "Chargebacks or refunds after your payout mean you owe #{money(-still)}#{covered}. " \
        "HåfaPass takes it from your next payout."
    elsif totals[:balance_remaining_cents].negative? && held.positive?
      notes << "Refunds or chargebacks after your payout (#{money(-totals[:balance_remaining_cents])}) come out of your " \
        "#{money(held)} reserve. You will get the remaining #{money(still)} when it is released."
    end
    @notes = notes
  end

  def money(cents)
    sign = cents.negative? ? "-" : ""
    "#{sign}#{ActiveSupport::NumberHelper.number_to_currency(BigDecimal(cents.abs) / 100)}"
  end
end
