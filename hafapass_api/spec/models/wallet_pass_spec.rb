require "rails_helper"

RSpec.describe WalletPass do
  let(:wallet_pass) do
    ticket = wallet_ticket
    described_class.create!(ticket: ticket, provider: "apple", serial_number: "ticket-#{ticket.id}-v1", scan_credential_version: 1)
  end

  it "keeps both tokens when two downloads record them from stale copies" do
    first = described_class.find(wallet_pass.id)
    second = described_class.find(wallet_pass.id)
    first.add_authentication_token!("first-download-token")
    second.add_authentication_token!("second-download-token")

    expect(wallet_pass.reload).to be_authenticates("first-download-token")
    expect(wallet_pass).to be_authenticates("second-download-token")
  end

  it "keeps microsecond tags and moves one pass forward by at least a second per change" do
    now = Time.zone.parse("2026-10-20 10:00:00.250000")
    allow(Time).to receive(:current).and_return(now)
    wallet_pass.record_content!("one")
    first = wallet_pass.update_tag
    wallet_pass.record_content!("two")

    expect(wallet_pass.update_tag.to_i).to eq(first.to_i + 1_000_000)
    expect(first).to eq((now.to_r * 1_000_000).to_i.to_s)
    expect(described_class.time_for_tag(first)).to eq(now)
  end
end
