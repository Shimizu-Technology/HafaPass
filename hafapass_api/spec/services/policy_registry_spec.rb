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
      include("heading" => "Your purchase", "body" => a_string_matching(/prices, fees/))
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
end
