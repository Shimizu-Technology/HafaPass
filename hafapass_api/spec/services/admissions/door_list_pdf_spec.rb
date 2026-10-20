require "rails_helper"
require "pdf/reader"

RSpec.describe Admissions::DoorListPdf do
  let(:event) { create(:event, :published, title: "괌 여름 축제 夏祭り") }
  let(:ticket_type) { create(:ticket_type, event: event, name: "一般入場") }

  def text_of(pdf)
    PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")
  end

  it "prints Korean, Japanese and Chinese names instead of question marks" do
    create(:ticket, event: event, ticket_type: ticket_type, attendee_name: "김민지")
    create(:ticket, event: event, ticket_type: ticket_type, attendee_name: "山田花子")
    create(:ticket, event: event, ticket_type: ticket_type, attendee_name: "陳小明")

    text = text_of(described_class.new(event).generate)

    expect(text).to include("괌 여름 축제 夏祭り", "김민지", "山田花子", "陳小明", "一般入場")
    expect(text).not_to include("???")
  end

  it "still prints when a name uses a script no bundled font covers" do
    create(:ticket, event: event, ticket_type: ticket_type, attendee_name: "Ana \u{10FFFF}")

    text = text_of(described_class.new(event).generate)

    expect(text).to include("Ana ?")
  end
end
