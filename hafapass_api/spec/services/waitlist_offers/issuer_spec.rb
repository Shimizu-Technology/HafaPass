require "rails_helper"

RSpec.describe WaitlistOffers::Issuer do
  it "reports exhausted inventory distinctly from an invalid ticket type" do
    event = create(:event, :published)
    create(:ticket_type, :sold_out, event: event)
    entry = create(:waitlist_entry, event: event)

    expect { described_class.call(entry: entry) }
      .to raise_error(described_class::OfferError, "No inventory is available for this waitlist entry")
  end
end
