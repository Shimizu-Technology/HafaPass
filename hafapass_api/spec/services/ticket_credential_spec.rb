require "rails_helper"

RSpec.describe TicketCredential do
  let(:ticket) { create(:ticket) }

  it "keeps display and scan credentials purpose-bound" do
    display = described_class.display(ticket)
    scan = described_class.scan(ticket)

    expect(display).not_to eq(scan)
    expect(described_class.find_display(display)).to eq(ticket)
    expect(described_class.find_scan(scan)).to eq(ticket)
    expect(described_class.find_scan(display)).to be_nil
    expect(described_class.find_display(scan)).to be_nil
  end

  it "rotates scan access without invalidating the display link" do
    display = ticket.display_credential
    old_scan = ticket.scan_credential
    ticket.rotate_scan_credential!

    expect(described_class.find_scan(old_scan)).to be_nil
    expect(described_class.find_display(display)).to eq(ticket)
    expect(described_class.find_scan(ticket.scan_credential)).to eq(ticket)
  end
end
