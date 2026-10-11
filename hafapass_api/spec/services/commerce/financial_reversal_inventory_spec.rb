require "rails_helper"
require Rails.root.join("db/migrate/20261011150000_retain_admitted_inventory_after_financial_reversal")

RSpec.describe Commerce::FinancialReversalInventory do
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_available: 2, quantity_sold: 2) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, order: order, event: event, ticket_type: ticket_type) }
  let(:refund) { create(:refund, order: order, amount_cents: order.total_cents) }

  it "retains a previously admitted ticket after Undo and records immutable exact financial evidence" do
    ticket.check_in!
    ticket.reverse_check_in!
    retention = described_class.call(ticket: ticket, refund: refund, reason: "synthetic refund")

    expect(ticket.reload).to be_issued
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(retention).to have_attributes(ticket_id: ticket.id, refund_id: refund.id, dispute_id: nil)
    expect(retention.reconciliation_exception).to be_open
    expect(retention.reconciliation_exception.details).to include("ticket_id" => ticket.id, "refund_id" => refund.id)
    expect(ticket).not_to be_admission_allowed
    expect { ticket.check_in! }.to raise_error(Ticket::AdmissionError, /requires organizer review/)
    expect { retention.update!(retained_at: Time.current + 1.hour) }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { retention.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)

    retention.reconciliation_exception.resolve!
    expect { described_class.call(ticket: ticket, refund: refund) }.not_to change(TicketInventoryRetention, :count)
    expect { ticket.release_inventory! }.to raise_error(Ticket::AdmissionError, /requires organizer review/)
    expect { ticket.update!(status: :cancelled) }.to raise_error(ActiveRecord::RecordInvalid, /cannot be cancelled or moved/)
    expect(ticket.reload).not_to be_admission_allowed
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end

  it "retains a checked-in legacy ticket without an admission journal and cancels only truly unused inventory" do
    ticket.update!(status: :checked_in, checked_in_at: nil)
    unused = create(:ticket, order: order, event: event, ticket_type: ticket_type)
    described_class.call(ticket: ticket, refund: refund)
    described_class.call(ticket: unused, refund: refund)

    expect(ticket.reload).to be_checked_in
    expect(unused.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(TicketInventoryRetention.count).to eq(1)
    expect { described_class.call(ticket: unused, refund: refund) }
      .not_to change { ticket_type.reload.quantity_sold }
  end

  it "does not retain or release inventory for an unproven or foreign financial origin" do
    pending = create(:refund, order: order, status: :pending, succeeded_at: nil)
    foreign = create(:refund)
    unrecorded = build(:refund, order: order)
    [pending, foreign, unrecorded].each do |origin|
      expect { described_class.call(ticket: ticket, refund: origin) }.to raise_error(ArgumentError)
    end
    expect { described_class.call(ticket: ticket) }.to raise_error(ArgumentError)
    expect(ticket.reload).to be_issued
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(TicketInventoryRetention.count).to eq(0)
  end

  it "enforces unique ticket retention and real foreign keys at the database boundary" do
    ticket.check_in!
    retention = described_class.call(ticket: ticket, refund: refund)
    attributes = retention.attributes.except("id")
    expect do
      TicketInventoryRetention.transaction(requires_new: true) { TicketInventoryRetention.insert_all!([attributes]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
    attributes["ticket_id"] = Ticket.maximum(:id) + 1000
    expect do
      TicketInventoryRetention.transaction(requires_new: true) { TicketInventoryRetention.insert_all!([attributes]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "backfills only existing legacy admission evidence, including reversed admissions, and guards rollback" do
    actor = event.organizer_profile.user
    known = 2.hours.ago
    AdmissionAction.create!(organization: event.organization, event: event, ticket: ticket,
      actor_user: actor, kind: :admit, source: :manual, result: :accepted, reason_code: "admitted",
      action_uuid: "synthetic-legacy-first-admission",
      received_at: known, occurred_at: known, scanner_device: nil, sequence: nil, manifest_version: nil)
    ticket.update!(status: :checked_in, checked_in_at: 1.hour.ago)
    unused = create(:ticket, order: order, event: event, ticket_type: ticket_type)
    migration = RetainAdmittedInventoryAfterFinancialReversal.new
    migration.backfill_first_admission
    expect(ticket.reload.first_admitted_at).to be_within(0.000001).of(known)
    expect(unused.reload.first_admitted_at).to be_nil
    ticket.reverse_check_in!
    described_class.call(ticket: ticket, refund: refund)
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /preserve its evidence/)
    expect(TicketInventoryRetention.count).to eq(1)
    expect(ticket.reload).not_to be_admission_allowed
  end

  it "refuses rollback when legacy check-in and Undo leave sole admission evidence without retention rows" do
    ticket.check_in!
    first = ticket.reload.first_admitted_at
    ticket.reverse_check_in!
    expect(ticket.reload).to be_issued
    expect(ticket.checked_in_at).to be_nil
    expect(ticket.admission_actions).to be_empty
    expect(TicketInventoryRetention.count).to eq(0)

    migration = RetainAdmittedInventoryAfterFinancialReversal.new
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /admission history/)
    expect(ticket.reload.first_admitted_at).to eq(first)
    expect(ActiveRecord::Base.connection.table_exists?(:ticket_inventory_retentions)).to be(true)
    retention = described_class.call(ticket: ticket, refund: refund)
    expect(retention.refund_id).to eq(refund.id)
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end

  it "allows actual PostgreSQL down and up when neither admission history nor retention evidence exists" do
    connection = ActiveRecord::Base.connection
    expect(TicketInventoryRetention.count).to eq(0)
    expect(Ticket.where.not(first_admitted_at: nil).count).to eq(0)
    migration = RetainAdmittedInventoryAfterFinancialReversal.new
    migration.down
    expect(connection.table_exists?(:ticket_inventory_retentions)).to be(false)
    expect(connection.column_exists?(:tickets, :first_admitted_at)).to be(false)
    migration.up
    expect(connection.table_exists?(:ticket_inventory_retentions)).to be(true)
    expect(connection.column_exists?(:tickets, :first_admitted_at)).to be(true)
    expect(TicketInventoryRetention.count).to eq(0)
  end

  it "preserves an existing legacy admission timestamp through Undo and subsequent refund retention" do
    known = 1.hour.ago
    ticket.update!(status: :checked_in, checked_in_at: known)
    stored = ticket.reload.checked_in_at
    expect(ticket.first_admitted_at).to be_nil
    expect(ticket.admission_actions).to be_empty
    ticket.reverse_check_in!
    expect(ticket.reload.first_admitted_at).to eq(stored)
    expect(ticket.checked_in_at).to be_nil
    retention = described_class.call(ticket: ticket, refund: refund)
    expect(retention.refund_id).to eq(refund.id)
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end

  it "uses an existing accepted action's earliest server timestamp when legacy Undo has no timestamp" do
    ticket.update!(status: :checked_in, checked_in_at: nil)
    known = 2.hours.ago
    AdmissionAction.create!(organization: event.organization, event: event, ticket: ticket,
      actor_user: event.organizer_profile.user, kind: :admit, source: :manual, result: :accepted,
      reason_code: "admitted", action_uuid: "synthetic-legacy-journal-undo", received_at: known, occurred_at: known)
    ticket.reverse_check_in!
    expect(ticket.reload.first_admitted_at).to be_within(0.000001).of(known)
    described_class.call(ticket: ticket, refund: refund)
    expect(ticket.reload).to be_inventory_retained
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end

  it "refuses unprotected unknown legacy Undo while permitting already-retained Undo without inventing a date" do
    ticket.update!(status: :checked_in, checked_in_at: nil)
    expect(ticket.first_admitted_at).to be_nil
    expect(ticket.admission_actions).to be_empty
    expect { ticket.reverse_check_in! }.to raise_error(Ticket::AdmissionError, /Admission history requires organizer review/)
    expect(ticket.reload).to be_checked_in
    expect(ticket.first_admitted_at).to be_nil
    retention = described_class.call(ticket: ticket, refund: refund)
    ticket.reverse_check_in!
    expect(ticket.reload).to be_issued
    expect(ticket.first_admitted_at).to be_nil
    expect(ticket.inventory_retention.id).to eq(retention.id)
    expect(ticket).to be_previously_admitted
    expect(ticket).not_to be_admission_allowed
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end
end
