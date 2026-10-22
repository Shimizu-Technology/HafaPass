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

  it "requires a fresh register approval when only the status or effective date changes" do
    base = described_class.send(:registry)
    acceptances = [described_class.buyer_terms[:digest], described_class.organizer_agreement[:digest]]
    before = described_class.registry_digest

    { "effective_date" => "2099-01-01", "status" => "superseded" }.each do |field, value|
      allow(described_class).to receive(:registry).and_return(base.merge(field => value))

      expect(described_class.registry_digest).not_to eq(before), "#{field} did not change the register digest"
      expect([described_class.buyer_terms[:digest], described_class.organizer_agreement[:digest]]).to eq(acceptances)
    end
  end

  it "keeps legal-review notes out of the public text and lists them for admins" do
    strings = described_class.public_documents.values.flat_map do |document|
      [document["title"], document["summary"]] + document["sections"].flat_map { |section| section.values_at("heading", "body") }
    end
    expect(strings.join("\n")).not_to match(/\[[^\]\n]+\]|Lawyer to confirm|Accountant to confirm/)
    expect(described_class.public_documents.values.flat_map(&:keys).uniq).not_to include("review_notes")
    expect(described_class.review_notes).to include(
      include(document: "buyer-terms", section: "Governing law and disputes", note: a_string_matching(/governing law/)),
      include(document: "organizer-agreement", section: "Tax information")
    )
    headings = described_class.public_documents.transform_values { |document| document.fetch("sections").map { |section| section.fetch("heading") } }
    described_class.review_notes.each { |note| expect(headings.fetch(note[:document])).to include(note[:section]) }
  end

  it "treats only technical problems as approval blockers" do
    expect(described_class).not_to be_draft
    expect(described_class.approval_blockers).to eq([])

    allow(described_class).to receive(:templates).and_return(
      "buyer-terms" => { "title" => "Buyer Terms", "summary" => "See [Lawyer note]", "sections" => [] }
    )
    expect(described_class.approval_blockers).to eq(["Bracketed drafting notes remain in the public text of: Buyer Terms"])

    allow(described_class).to receive(:templates).and_return(
      "buyer-terms" => { "title" => "Buyer Terms", "summary" => "{{not_a_setting}}", "sections" => [] }
    )
    expect(described_class.approval_blockers).to eq(["A policy uses an unknown template placeholder (not_a_setting)"])
  end

  it "serves the owner-approved policies with a shared effective date" do
    expect(described_class.version).to eq("2026-10-22")
    expect(described_class.effective_date).to eq("2026-10-22")
    expect(described_class.status).to eq("approved")
    expect(described_class.review_summary).to include(draft: false, effective_date: "2026-10-22")
    expect(described_class.public_documents.keys).to include(
      "buyer-terms", "refunds", "privacy", "organizer-agreement", "acceptable-use", "retention", "cookies", "accessibility"
    )
    expect(described_class.public_documents.to_json).not_to match(/draft|pending counsel|subject to review|not final/i)
  end

  it "states the agent-of-payee, refund liability and tax roles without public drafting notes" do
    documents = described_class.public_documents
    organizer = documents.fetch("organizer-agreement").to_json
    buyer = documents.fetch("buyer-terms").to_json
    expect(organizer).to include("solely to accept buyer payments", "fully discharges", "not a party",
      "pay you by check", "refunds beyond the funds", "Business Privilege Tax", "W-9", "indemnify")
    expect(buyer).to include("fully discharges", "organizer is responsible for the event")
    expect(documents.fetch("privacy").to_json).to include("tax identification number", "encrypted at rest", "tax authorities")
    expect(documents.values.flat_map { |document| document.fetch("sections").map { |section| section.fetch("body") } }.join).not_to match(/\[[^\]]+\]/)
  end

  it "fills platform, operator, support and fee placeholders from current settings" do
    SiteSetting.instance.update!(platform_name: "HåfaPass", platform_email: "help@example.test",
      service_fee_percent: 4.5, service_fee_flat_cents: 75, processing_fee_bearer: "platform",
      payout_schedule_text: "within 5 business days after your event")
    text = JSON.generate(described_class.public_documents)

    expect(text).not_to match(/\{\{[a-z_]*\}\}/)
    expect(text).to include("contact us at help@example.test", "Shimizu Technology LLC", "within 5 business days after your event",
      "4.5% of each paid ticket's price plus $0.75 per paid ticket; free tickets carry no service fee; " \
      "card processing is paid by HåfaPass out of this fee")
    expect(text).not_to include("privacy@hafapass.com")
    expect(text).not_to match(/service fee is a tax|fee \(tax\)/i)
  end

  it "falls back to a usable support mailbox when no support email is configured" do
    SiteSetting.instance.update!(platform_email: nil)
    text = described_class.public_documents.to_s
    expect(text).to include("contact us at shimizutechnology@gmail.com")
    expect(text).not_to include("Help page")
  end

  it "requires organizers to re-accept when the fee schedule in the agreement changes" do
    profile = create(:organizer_profile, :verified)
    expect(profile).to be_policy_accepted
    buyer_digest = described_class.buyer_terms[:digest]

    SiteSetting.instance.update!(service_fee_flat_cents: SiteSetting.instance.service_fee_flat_cents + 25)

    expect(profile.reload).not_to be_policy_accepted
    expect(described_class.buyer_terms[:digest]).not_to eq(buyer_digest)
    expect(described_class.buyer_terms[:version]).to eq("2026-10-22")
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
