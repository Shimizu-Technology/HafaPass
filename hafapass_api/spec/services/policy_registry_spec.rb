require "rails_helper"

RSpec.describe PolicyRegistry do
  let(:templates) { YAML.safe_load_file(described_class::DOCUMENT_PATH).fetch("documents") }

  it "binds the buyer snapshot digest to the policy templates and the material terms" do
    canonical = JSON.generate({
      "version" => described_class.buyer_terms[:version],
      "documents" => described_class::BUYER_DOCUMENT_KEYS.to_h { |key| [key, templates.fetch(key)] },
      "material_terms_digest" => described_class.material_terms_digest
    })

    expect(described_class.buyer_terms[:digest]).to eq(Digest::SHA256.hexdigest(canonical))
    expect(described_class.public_documents.dig("buyer-terms", "sections")).to include(
      include("heading" => "Prices and the service fee", "body" => a_string_matching(/including the mandatory service fee/))
    )
  end

  it "binds the organizer snapshot to the organizer agreement template and the material terms" do
    canonical = JSON.generate({
      "version" => described_class.organizer_agreement[:version],
      "documents" => { "organizer-agreement" => templates.fetch("organizer-agreement") },
      "material_terms_digest" => described_class.material_terms_digest
    })

    expect(described_class.organizer_agreement[:digest]).to eq(Digest::SHA256.hexdigest(canonical))
  end

  it "keeps every digest and the register approval when only cosmetic settings change" do
    profile = create(:organizer_profile, :verified)
    before = [described_class.registry_digest, described_class.buyer_terms, described_class.organizer_agreement,
      PlatformCapabilities.configuration_digest("policy_register")]

    SiteSetting.instance.update!(platform_name: "HåfaPass Guam", platform_email: "launch@example.test", platform_phone: "671-555-0100")

    expect([described_class.registry_digest, described_class.buyer_terms, described_class.organizer_agreement,
      PlatformCapabilities.configuration_digest("policy_register")]).to eq(before)
    expect(profile.reload).to be_policy_accepted
    expect(JSON.generate(described_class.public_documents)).to include("launch@example.test", "HåfaPass Guam")
  end

  it "changes the digests and register configuration when fee or payout terms change" do
    %i[service_fee_percent service_fee_flat_cents processing_fee_bearer payout_schedule_text].each do |field|
      settings = SiteSetting.instance
      before = [described_class.registry_digest, described_class.organizer_agreement[:digest],
        described_class.buyer_terms[:digest], PlatformCapabilities.configuration_digest("policy_register")]
      value = { service_fee_percent: settings.service_fee_percent + 1, service_fee_flat_cents: settings.service_fee_flat_cents + 5,
        processing_fee_bearer: settings.platform_bears_processing? ? "organizer" : "platform",
        payout_schedule_text: "#{settings.payout_schedule_text} (updated)" }.fetch(field)
      settings.update!(field => value)

      after = [described_class.registry_digest, described_class.organizer_agreement[:digest],
        described_class.buyer_terms[:digest], PlatformCapabilities.configuration_digest("policy_register")]
      after.zip(before).each { |now, was| expect(now).not_to eq(was), "#{field} did not change a digest" }
    end
  end

  it "lists approval blockers while the text is a draft with bracketed review notes" do
    expect(described_class.approval_blockers).to include(a_string_matching(/status is draft-pending-legal-review/),
      a_string_matching(/Unresolved review notes in brackets remain in: .*Buyer Terms/))
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
    expect(text).to include("contact us at help@example.test", "Shimizu Technology", "within 5 business days after your event",
      "4.5% of each paid ticket's price plus $0.75 per paid ticket; free tickets carry no service fee; " \
      "card processing is paid by HåfaPass out of this fee")
    expect(text).not_to include("privacy@hafapass.com")
    expect(text).not_to match(/service fee is a tax|fee \(tax\)/i)
  end

  it "falls back to a plain support pointer when no support email is configured" do
    SiteSetting.instance.update!(platform_email: nil)
    text = described_class.public_documents.to_s
    expect(text).to include("contact us through Find your tickets → Contact support (/orders/recover)")
    expect(text).not_to include("Help page")
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
