require "rails_helper"

RSpec.describe TicketTransfers::Manager do
  let(:owner) { create(:user, email: "owner@example.com") }
  let(:recipient) { create(:user, email: "recipient@example.com") }
  let(:event) { create(:event, :published, starts_at: 2.days.from_now) }
  let(:order) { create(:order, event: event, user: owner, buyer_email: owner.email) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:item) { create(:order_item, order: order, ticket_type: ticket_type) }
  let(:ticket) { create(:ticket, order: order, event: event, ticket_type: ticket_type, order_item: item) }

  it "accepts only as the invited user and rotates both credentials" do
    old_display = ticket.display_credential
    old_scan = ticket.scan_credential
    transfer = described_class.create!(ticket: ticket, recipient_email: recipient.email, initiated_by: owner)
    token = TicketTransferCredential.issue(transfer)

    expect { described_class.accept!(token: token, user: owner) }
      .to raise_error(described_class::TransferError, /email address that received/)
    described_class.accept!(token: token, user: recipient)

    expect(ticket.reload.holder_user).to eq(recipient)
    expect(TicketCredential.find_display(old_display)).to be_nil
    expect(TicketCredential.find_scan(old_scan)).to be_nil
    expect(TicketTransferCredential.find(token)).to be_nil
    expect(OrderPresenter.call(order.reload, include_tickets: true)[:tickets].first)
      .to include(status: "transferred", display_credential: nil, scan_credential: nil)
  end

  it "prevents two active transfers for one ticket" do
    described_class.create!(ticket: ticket, recipient_email: recipient.email)
    expect { described_class.create!(ticket: ticket, recipient_email: "other@example.com") }
      .to raise_error(described_class::TransferError, /already has a pending transfer/)
  end
end
