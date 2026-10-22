require "rails_helper"

RSpec.describe WaitlistOffers::Issuer do
  it "refuses an uncertified organizer before creating an offer" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket = create(:ticket_type, event: event, quantity_available: 2)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket)
    expect { described_class.call(entry: entry) }
      .to raise_error(described_class::OfferError, /business mailing address/)
    expect(entry.reload).to be_waiting
    expect(WaitlistOffer.where(waitlist_entry: entry)).not_to exist
  end
  it "reports exhausted inventory distinctly from an invalid ticket type" do
    event = create(:event, :published)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    create(:ticket_type, :sold_out, event: event)
    entry = create(:waitlist_entry, event: event)

    expect { described_class.call(entry: entry) }
      .to raise_error(described_class::OfferError, "No inventory is available for this waitlist entry")
  end
end
