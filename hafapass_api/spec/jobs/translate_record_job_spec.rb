require "rails_helper"

RSpec.describe TranslateRecordJob, type: :job do
  include ActiveJob::TestHelper

  let(:event) { create(:event, :published, title: "Sunset Fiesta", short_description: "Music by the bay", description: "") }
  let(:service) { instance_double(GtTranslationService) }

  def fake_translations(fields, locales = AppLocale::TRANSLATION_TARGETS, prefix: nil)
    fields.transform_values { |text| Array(locales).index_with { |locale| "[#{prefix}#{locale}] #{text}" } }
  end

  before do
    with_gt_credentials
    allow(GtTranslationService).to receive(:new).and_return(service)
    allow(service).to receive(:translate) { |fields, locales:, **| fake_translations(fields, locales) }
  end

  it "queues translation of only the changed organizer text after commit" do
    expect { event }.to have_enqueued_job(described_class)
      .with("Event", kind_of(Integer), match_array(%w[title short_description description]), false)
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
      context: Event.translation_context, locales: ["ko"])
  end

  it "is idempotent: nothing is requested again unless forced" do
    described_class.perform_now("Event", event.id, nil, false)
    expect(service).to have_received(:translate).exactly(AppLocale::TRANSLATION_TARGETS.size).times

    described_class.perform_now("Event", event.id, nil, false)
    expect(service).to have_received(:translate).exactly(AppLocale::TRANSLATION_TARGETS.size).times

    described_class.perform_now("Event", event.id, nil, true)
    expect(service).to have_received(:translate).exactly(2 * AppLocale::TRANSLATION_TARGETS.size).times
  end

  it "requests only missing locales and keeps good locales a forced retranslation did not return" do
    allow(service).to receive(:translate) do |fields, locales:, **|
      locales == ["ja"] ? {} : fake_translations(fields, locales)
    end
    described_class.perform_now("Event", event.id, nil, false)
    expect(event.reload.translations["title"]).not_to have_key("ja")
    expect(event.translation_status).to eq("failed")

    allow(service).to receive(:translate) { |fields, locales:, **| fake_translations(fields, locales, prefix: "new ") }
    described_class.perform_now("Event", event.id, nil, false)
    expect(service).to have_received(:translate).exactly(AppLocale::TRANSLATION_TARGETS.size + 1).times
    expect(service).to have_received(:translate).with({ "title" => "Sunset Fiesta", "short_description" => "Music by the bay" }, context: anything, locales: ["ja"]).twice
    expect(event.reload.translations["title"]).to include("ja" => "[new ja] Sunset Fiesta", "ko" => "[ko] Sunset Fiesta")

    allow(service).to receive(:translate) { |fields, locales:, **| locales == ["ko"] ? {} : fake_translations(fields, locales, prefix: "forced ") }
    described_class.perform_now("Event", event.id, nil, true)
    expect(event.reload.translations["title"]).to include("ko" => "[ko] Sunset Fiesta", "ja" => "[forced ja] Sunset Fiesta")
    expect(event.translation_status).to eq("translated")
  end

  it "never stores a translation of English that changed while the request was in flight" do
    allow(service).to receive(:translate) do |fields, locales:, **|
      Event.where(id: event.id).update_all(title: "Renamed Fiesta")
      fake_translations(fields, locales)
    end

    described_class.perform_now("Event", event.id, %w[title], false)

    event.reload
    expect(event.translations).not_to have_key("title")
    expect(event.content_for("ko")[:title]).to eq("Renamed Fiesta")
  end

  it "retries service failures and marks the record failed when retries run out" do
    event
    allow(service).to receive(:translate).and_raise(GtTranslationService::TranslationError, "HTTP 503")

    perform_enqueued_jobs(only: described_class) { described_class.perform_later("Event", event.id, nil, false) }

    expect(service).to have_received(:translate).exactly(4).times
    expect(event.reload.translation_status).to eq("failed")
  end

  it "does not let a failed job overwrite a translation another job completed" do
    described_class.perform_now("Event", event.id, nil, false)
    job = described_class.new("Event", event.id, nil, true)

    job.settle("failed", GtTranslationService::TranslationError.new("late failure"))

    expect(event.reload.translation_status).to eq("translated")
  end

  it "records an out-of-credit service as unavailable without retrying" do
    event
    allow(service).to receive(:translate).and_raise(GtTranslationService::Unavailable, "HTTP 402")

    perform_enqueued_jobs(only: described_class) { described_class.perform_later("Event", event.id, nil, false) }

    expect(service).to have_received(:translate).once
    expect(event.reload.translation_status).to eq("unavailable")
  end

  it "translates ticket type names and descriptions" do
    ticket_type = create(:ticket_type, event: event, name: "General Admission", description: "Lawn seating")
    described_class.perform_now("TicketType", ticket_type.id, nil, false)

    expect(ticket_type.reload.content_for("ja")).to eq(name: "[ja] General Admission", description: "[ja] Lawn seating",
      machine_translated: true)
  end

  it "sends nothing for drafts and translates everything once the event is published" do
    draft = nil
    expect { draft = create(:event, title: "Private Fiesta") }.not_to have_enqueued_job(described_class)
    ticket_type = create(:ticket_type, event: draft, name: "VIP")
    expect(draft.reload.translation_status).to eq("untranslated")
    described_class.perform_now("Event", draft.id, nil, true)
    expect(service).not_to have_received(:translate)

    expect { draft.update!(status: :published, published_at: Time.current) }
      .to have_enqueued_job(described_class).with("Event", draft.id, match_array(Event::CONTENT_FIELDS), false)
      .and have_enqueued_job(described_class).with("TicketType", ticket_type.id, nil, false)
  end

  it "is a no-op when the machine translation switch is off, even with credentials" do
    with_gt_credentials(machine_translation: false)
    expect { event.update!(title: "New title") }.not_to have_enqueued_job(described_class)
    event.update_column(:translation_status, "pending")

    described_class.perform_now("Event", event.id, nil, false)

    expect(service).not_to have_received(:translate)
    expect(event.reload.translation_status).to eq("untranslated")
  end

  it "settles a completed partial job as untranslated so backfill can recover missing fields" do
    described_class.perform_now("Event", event.id, %w[title], false)

    expect(event.reload.translation_status).to eq("untranslated")
    expect(event.translation_complete?).to be(false)

    described_class.perform_now("Event", event.id, nil, false)
    expect(event.reload.translation_status).to eq("translated")
  end

  it "requests and requires only enabled non-English locales" do
    with_locales_enabled(%w[en ko], machine_translation: true)

    described_class.perform_now("Event", event.id, nil, false)

    expect(service).to have_received(:translate).once.with(anything, context: anything, locales: ["ko"])
    expect(event.reload.translations["title"].keys).to contain_exactly("ko", "_digest")
    expect(event.machine_translation_current?("title")).to be(true)
    expect(event.translation_complete?).to be(true)
    expect(event.translation_status).to eq("translated")

    with_locales_enabled(%w[en ko ja], machine_translation: true)
    expect(event.machine_translation_current?("title")).to be(false)
    expect(event.translation_complete?).to be(false)
  end

  it "sends nothing to General Translation when only English is enabled" do
    with_locales_enabled(%w[en], machine_translation: true)
    described_class.perform_now("Event", event.id, nil, true)
    expect(service).not_to have_received(:translate)
  end

  it "ignores unknown classes and missing records" do
    expect { described_class.perform_now("User", 1, nil, false) }.not_to raise_error
    expect { described_class.perform_now("Event", 0, nil, false) }.not_to raise_error
    expect(service).not_to have_received(:translate)
  end
end
