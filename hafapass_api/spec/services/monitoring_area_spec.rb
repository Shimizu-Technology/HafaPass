# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonitoringArea do
  it "names the checkout, webhook, scanner and box-office paths and nothing else" do
    expect(described_class.for_controller("api/v1/orders")).to eq("checkout")
    expect(described_class.for_controller("api/v1/order_recovery")).to eq("checkout")
    expect(described_class.for_controller("webhooks")).to eq("webhook")
    expect(described_class.for_controller("api/v1/organizer/scanner_devices")).to eq("scanner")
    expect(described_class.for_controller("api/v1/organizer/admissions")).to eq("scanner")
    expect(described_class.for_controller("api/v1/organizer/box_office")).to eq("box_office")
    expect(described_class.for_controller("api/v1/organizer/box_office_receipts")).to eq("box_office")
    expect(described_class.for_controller("api/v1/events")).to be_nil
  end
end
