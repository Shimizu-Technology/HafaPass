require "rails_helper"

RSpec.describe MessageDelivery do
  it "keeps the documented email classification identical to the send-time classification" do
    document = File.read(Rails.root.join("..", "docs", "EMAIL_COMPLIANCE.md"))
    rows = document.scan(/^\| `([^`]+)` \| ([^|]+) \|/).to_h.transform_values do |classification|
      classification.strip == "Commercial" ? :commercial : :transactional
    end

    expect(rows).to eq(described_class::EMAIL_TEMPLATE_CLASSIFICATION)
  end
end
