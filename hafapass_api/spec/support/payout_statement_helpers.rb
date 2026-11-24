# frozen_string_literal: true

# Fictional settled sales for payout schedule and statement specs. Each card
# sale mirrors what checkout records: order, line item, platform fee
# component, captured payment and the verified actual Stripe processing cost.
module PayoutStatementHelpers
  def guam(*args)
    ActiveSupport::TimeZone["Pacific/Guam"].local(*args)
  end

  def record_card_sale!(event, ticket_type:, quantity: 1, unit_price_cents: ticket_type.price_cents, buyer_fee_cents: 100,
    organizer_fee_cents: 0, discount_cents: 0, processing_fee_cents: 60, bearer: "organizer", completed_at: Time.current)
    subtotal = unit_price_cents * quantity
    fees = buyer_fee_cents * quantity
    total = subtotal - discount_cents + fees
    order = create(:order, event: event, subtotal_cents: subtotal, service_fee_cents: fees,
      organizer_fee_cents: organizer_fee_cents, discount_cents: discount_cents, total_cents: total,
      processing_fee_bearer_snapshot: bearer, completed_at: completed_at)
    item = create(:order_item, order: order, ticket_type: ticket_type, name: ticket_type.name,
      unit_price_cents: unit_price_cents, quantity: quantity, subtotal_cents: subtotal, discount_cents: discount_cents,
      fee_cents: fees, organizer_fee_cents: organizer_fee_cents,
      organizer_proceeds_cents: subtotal - discount_cents - organizer_fee_cents)
    create(:fee_component, order: order, kind: "platform", amount_cents: fees + organizer_fee_cents, estimated: true)
    capture = create(:payment, :succeeded, order: order, amount_cents: total)
    if processing_fee_cents.positive?
      component = create(:fee_component, order: order, order_item: item, kind: "processing",
        amount_cents: processing_fee_cents, estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
      create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)
    end
    [order, item, capture]
  end

  # A partial or full card refund of the organizer's share plus the buyer fee.
  def record_card_refund!(order, item, capture, proceeds_cents:, fee_cents: 0, quantity: 1)
    refund = create(:refund, order: order, payment: capture, amount_cents: proceeds_cents + fee_cents)
    create(:refund_item, refund: refund, order_item: item, amount_cents: proceeds_cents + fee_cents,
      organizer_proceeds_cents: proceeds_cents, fee_cents: fee_cents, quantity: quantity)
    fully = order.refunds.succeeded.sum(:amount_cents) >= order.total_cents
    order.update_columns(status: Order.statuses[fully ? :refunded : :partially_refunded])
    refund
  end

  def record_door_cash_sale!(event, ticket_type:, user:, quantity: 1, key: SecureRandom.hex(6))
    allow(EmailService).to receive(:send_order_confirmation_async)
    Commerce::CashSaleCreator.call(event: event, user: user,
      parameters: { line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }], payment_method: "door_cash" },
      idempotency_key: "door-cash-#{key}").order
  end

  def record_lost_chargeback!(order, capture, amount_cents: order.total_cents, at: Time.current)
    Dispute.create!(order: order, payment: capture, amount_cents: amount_cents, currency: order.currency,
      provider_dispute_id: "dp_fixture_#{SecureRandom.hex(6)}", status: :lost, opened_at: at - 1.day, closed_at: at,
      reason: "fraudulent")
  end

  def approved_bank_account!(organization, actor:, admin:, last_four: "4321")
    create(:organizer_tax_information, organization: organization) unless organization.organizer_tax_information
    account = ConnectedAccounts::Manager.start!(organization: organization, provider: "manual", actor: actor,
      payout_details: { bank_name: "Example Island Bank", account_holder_name: "Fictional Sports Club",
        account_number: "99887766#{last_four}" })
    PayoutMethodReview.approve!(account: account, actor: admin,
      controls: PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true),
      expected_digest: PayoutMethodReview.digest(account))
    ConnectedAccounts::Manager.select!(account: account.reload, actor: actor)
    account.reload
  end

  # Statement lines must add up to their section totals, and the last total
  # must be the settlement calculator's own balance.
  def expect_statement_to_reconcile(statement, event)
    statement = statement.deep_symbolize_keys
    attributes = Settlements::Calculator.call(event).attributes
    sections = statement.fetch(:sections)
    running = 0
    sections.each do |section|
      running += section.fetch(:lines).sum { |line| line.fetch(:amount_cents) }
      expect(section.fetch(:total_cents)).to eq(running), "#{section[:title]} total"
    end
    expect(sections.first.fetch(:total_cents)).to eq(attributes.fetch(:organizer_proceeds_cents))
    expect(sections.last.fetch(:total_cents)).to eq(PayoutSchedule.balance_before_payout_cents(attributes))
    expect(statement.fetch(:sales_by_ticket).sum { |row| row.fetch(:gross_cents) })
      .to eq(sections.first.fetch(:lines).first.fetch(:amount_cents))
    totals = statement.fetch(:totals)
    expect(totals.fetch(:balance_remaining_cents))
      .to eq(sections.last.fetch(:total_cents) - totals.fetch(:transferred_cents) - totals.fetch(:in_progress_cents))
    expect(totals.fetch(:transferred_cents)).to eq(event.payouts.status_paid.sum(:amount_cents))
    expect(totals.fetch(:still_to_come_cents)).to eq(totals.fetch(:balance_remaining_cents) + totals.fetch(:reserve_held_cents))
    expect(statement.fetch(:closing).fetch(:total_cents)).to eq(totals.fetch(:still_to_come_cents))
    expect(statement.fetch(:notes).any? { |note| note.include?("you owe") }).to eq(totals.fetch(:still_to_come_cents).negative?)
    expect(statement.fetch(:contradictions)).to eq([])
    expect(statement.fetch(:reconciles)).to be(true)
    expect(statement.fetch(:difference_cents)).to eq(0)
  end
end

RSpec.configure { |config| config.include PayoutStatementHelpers }
