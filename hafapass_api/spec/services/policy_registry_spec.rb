require "rails_helper"

RSpec.describe PolicyRegistry do
  it "binds the buyer snapshot digest to the exact served policy content" do
    documents = described_class.public_documents
    buyer_documents = described_class::BUYER_DOCUMENT_KEYS.to_h { |key| [key, documents.fetch(key)] }
    canonical = JSON.generate({
      "version" => described_class.buyer_terms[:version],
      "documents" => buyer_documents
    })

    expect(described_class.buyer_terms[:digest]).to eq(Digest::SHA256.hexdigest(canonical))
    expect(documents.dig("buyer-terms", "sections")).to include(
      include("heading" => "Prices and the service fee", "body" => a_string_matching(/including the mandatory service fee/))
    )
  end

  it "binds the organizer snapshot to the served organizer agreement" do
    documents = described_class.public_documents
    canonical = JSON.generate({
      "version" => described_class.organizer_agreement[:version],
      "documents" => { "organizer-agreement" => documents.fetch("organizer-agreement") }
    })

    expect(described_class.organizer_agreement[:digest]).to eq(Digest::SHA256.hexdigest(canonical))
  end

  it "serves the launch draft, clearly marked as pending legal review" do
    expect(described_class.version).to eq("2026-10-launch-draft")
    expect(described_class.status).to eq("draft-pending-legal-review")
    expect(described_class.public_documents.keys).to include(
      "buyer-terms", "refunds", "privacy", "organizer-agreement", "acceptable-use", "retention", "cookies", "accessibility"
    )
    described_class.public_documents.each_value do |document|
      expect(document.fetch("summary")).to end_with("Draft pending legal review.")
    end
  end

  it "fills platform, operator, support and fee placeholders from current settings" do
    SiteSetting.instance.update!(platform_name: "HåfaPass", platform_email: "help@example.test",
      service_fee_percent: 4.5, service_fee_flat_cents: 75, processing_fee_bearer: "platform",
      payout_schedule_text: "within 5 business days after your event")
    text = JSON.generate(described_class.public_documents)

    expect(text).not_to match(/\{\{[a-z_]*\}\}/)
    expect(text).to include("help@example.test", "Shimizu Technology", "within 5 business days after your event",
      "4.5% of each paid ticket's price plus $0.75 per paid ticket; free tickets carry no service fee; " \
      "card processing is paid by HåfaPass out of this fee")
    expect(text).not_to include("privacy@hafapass.com")
    expect(text).not_to match(/service fee is a tax|fee \(tax\)/i)
  end

  it "falls back to a plain support pointer when no support email is configured" do
    SiteSetting.instance.update!(platform_email: nil)
    expect(JSON.generate(described_class.public_documents)).to include(described_class::SUPPORT_FALLBACK)
  end

  it "requires organizers to re-accept when the fee schedule in the agreement changes" do
    profile = create(:organizer_profile, :verified)
    expect(profile).to be_policy_accepted
    buyer_digest = described_class.buyer_terms[:digest]

    SiteSetting.instance.update!(service_fee_flat_cents: SiteSetting.instance.service_fee_flat_cents + 25)

    expect(profile.reload).not_to be_policy_accepted
    expect(described_class.buyer_terms[:digest]).not_to eq(buyer_digest)
    expect(described_class.buyer_terms[:version]).to eq("2026-10-launch-draft")
  end

  it "treats acceptance of the previous pilot draft as stale" do
    profile = create(:organizer_profile, :verified)
    profile.update!(policy_version: "2026-07-pilot-draft")
    expect(profile).not_to be_policy_accepted
  end

  it "rejects an unknown placeholder instead of serving it" do
    allow(described_class).to receive(:registry).and_return(
      { "version" => "x", "documents" => { "buyer-terms" => { "title" => "{{unknown_token}}" } } }
    )
    expect { described_class.public_documents }.to raise_error(KeyError)
  end
end
