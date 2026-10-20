require "rails_helper"

RSpec.describe TranslateRecordJob, type: :job do
  include ActiveJob::TestHelper

  let(:event) { create(:event, :published, title: "Sunset Fiesta", short_description: "Music by the bay", description: "") }
  let(:service) { instance_double(GtTranslationService) }

  def fake_translations(fields)
    fields.transform_values { |text| AppLocale::TRANSLATION_TARGETS.index_with { |locale| "[#{locale}] #{text}" } }
  end

  before do
    with_gt_credentials
    allow(GtTranslationService).to receive(:new).and_return(service)
    allow(service).to receive(:translate) { |fields, **| fake_translations(fields) }
  end

  it "queues translation of only the changed organizer text after commit" do
    expect { event }.to have_enqueued_job(described_class).with("Event", kind_of(Integer), match_array(%w[title short_description description]), false)
    expect(event.reload.translation_status).to eq("pending")

    expect { event.update!(max_capacity: 500) }.not_to have_enqueued_job(described_class)
    expect { event.update!(description: "Bring a chair") }
      .to have_enqueued_job(described_class).with("Event", event.id, %w[description], false)
  end

  it "stores translations with the source digest and marks the record translated" do
    described_class.perform_now("Event", event.id, nil, false)

    event.reload
    expect(event.translation_status).to eq("translated")
    expect(event.translations["title"]).to include("ko" => "[ko] Sunset Fiesta", "tl" => "[tl] Sunset Fiesta",
      "_digest" => Translatable.digest("Sunset Fiesta"))
    expect(event.translations).not_to have_key("description")
    expect(service).to have_received(:translate).with({ "title" => "Sunset Fiesta", "short_description" => "Music by the bay" },
      context: Event.translation_context)
  end

  it "is idempotent: current translations are not requested again unless forced" do
    described_class.perform_now("Event", event.id, nil, false)
    described_class.perform_now("Event", event.id, nil, false)
    expect(service).to have_received(:translate).with({}, context: anything).once

    described_class.perform_now("Event", event.id, nil, true)
    expect(service).to have_received(:translate).with(hash_including("title"), context: anything).twice
  end

  it "never stores a translation of English that changed while the request was in flight" do
    allow(service).to receive(:translate) do |fields, **|
      Event.where(id: event.id).update_all(title: "Renamed Fiesta")
      fake_translations(fields)
    end

    described_class.perform_now("Event", event.id, %w[title], false)

    event.reload
    expect(event.translations).not_to have_key("title")
    expect(event.content_for("ko")[:title]).to eq("Renamed Fiesta")
  end

  it "marks the record failed when a locale is missing from the response" do
    allow(service).to receive(:translate) { |fields, **| fake_translations(fields).transform_values { |value| value.except("ja") } }

    described_class.perform_now("Event", event.id, nil, false)
    expect(event.reload.translation_status).to eq("failed")
  end

  it "retries service failures and marks the record failed when retries run out" do
    event
    allow(service).to receive(:translate).and_raise(GtTranslationService::TranslationError, "HTTP 503")

    perform_enqueued_jobs(only: described_class) { described_class.perform_later("Event", event.id, nil, false) }

    expect(service).to have_received(:translate).exactly(4).times
    expect(event.reload.translation_status).to eq("failed")
  end

  it "translates ticket type names and descriptions" do
    ticket_type = create(:ticket_type, event: event, name: "General Admission", description: "Lawn seating")
    described_class.perform_now("TicketType", ticket_type.id, nil, false)

    expect(ticket_type.reload.content_for("ja")).to eq(name: "[ja] General Admission", description: "[ja] Lawn seating",
      machine_translated: true)
  end

  it "is a no-op without credentials and clears a stuck pending status" do
    allow(GtTranslationService).to receive(:configured?).and_return(false)
    event.update_column(:translation_status, "pending")

    described_class.perform_now("Event", event.id, nil, false)

    expect(service).not_to have_received(:translate)
    expect(event.reload.translation_status).to eq("untranslated")
  end

  it "ignores unknown classes and missing records" do
    expect { described_class.perform_now("User", 1, nil, false) }.not_to raise_error
    expect { described_class.perform_now("Event", 0, nil, false) }.not_to raise_error
    expect(service).not_to have_received(:translate)
  end
end
