require "rails_helper"

RSpec.describe "Event translations and buyer language", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organizer) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: organizer) }
  let(:event) do
    create(:event, :published, organizer_profile: organizer_profile, title: "Sunset Fiesta",
      short_description: "Music by the bay", description: "Bring a chair", starts_at: 5.days.from_now)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, name: "General Admission", description: "Lawn seating") }

  def machine_translate!(record, fields)
    record.update_columns(translations: fields.to_h { |field|
      [field, AppLocale::TRANSLATION_TARGETS.index_with { |locale| "#{locale}:#{record[field]}" }
        .merge("_digest" => Translatable.digest(record[field]))]
    }, translation_status: "translated")
  end

  describe "public event text" do
    before do
      with_locales_enabled(AppLocale::SUPPORTED, machine_translation: true)
      machine_translate!(event, Event::CONTENT_FIELDS)
      machine_translate!(ticket_type, %w[name description])
    end

    it "returns the Accept-Language translation with the original and a machine-translated flag" do
      get "/api/v1/events/#{event.slug}", headers: { "Accept-Language" => "zh-TW,zh;q=0.9,en;q=0.5" }

      body = response.parsed_body
      expect(response.headers["Vary"]).to include("Accept-Language")
      expect(body).to include("title" => "zh-Hant:Sunset Fiesta", "description" => "zh-Hant:Bring a chair",
        "content_locale" => "zh-Hant", "machine_translated" => true)
      expect(body["original_content"]).to include("title" => "Sunset Fiesta", "description" => "Bring a chair")
      expect(body["ticket_types"].first).to include("name" => "zh-Hant:General Admission", "machine_translated" => true,
        "original_name" => "General Admission", "original_description" => "Lawn seating")
    end

    it "lets ?locale= override the header and serves English with no original block" do
      get "/api/v1/events/#{event.slug}", params: { locale: "tl" }, headers: { "Accept-Language" => "ko" }
      expect(response.parsed_body).to include("title" => "tl:Sunset Fiesta", "content_locale" => "tl")

      get "/api/v1/events", headers: { "Accept-Language" => "en-US" }
      listed = response.parsed_body["events"].find { |value| value["id"] == event.id }
      expect(listed).to include("title" => "Sunset Fiesta", "machine_translated" => false, "original_content" => nil)
    end

    it "serves English while the server has not enabled the language or machine translation" do
      with_locales_enabled(%w[en])
      get "/api/v1/events/#{event.slug}", headers: { "Accept-Language" => "ko" }
      expect(response.parsed_body).to include("title" => "Sunset Fiesta", "content_locale" => "en", "machine_translated" => false)

      with_locales_enabled(%w[ko], machine_translation: false)
      get "/api/v1/events/#{event.slug}", headers: { "Accept-Language" => "ko" }
      expect(response.parsed_body).to include("title" => "Sunset Fiesta", "content_locale" => "ko", "machine_translated" => false)
    end

    it "prefers the organizer's own translation over machine translation" do
      event.update!(supported_locales: %w[en ko], localized_content: { "ko" => { "title" => "선셋 피에스타" } })

      get "/api/v1/events/#{event.slug}", headers: { "Accept-Language" => "ko-KR" }
      expect(response.parsed_body).to include("title" => "선셋 피에스타", "short_description" => "ko:Music by the bay")
    end
  end

  describe "organizer content and retranslation" do
    let(:headers) { auth_headers(organizer) }

    it "saves organizer translations for the new languages and reports the translation status" do
      patch "/api/v1/organizer/events/#{event.id}", headers: headers, params: {
        supported_locales: %w[en zh-Hant tl],
        localized_content: { "zh-Hant" => { "title" => "日落節", "description" => "請帶椅子" }, "tl" => { "title" => "Pista" } }
      }

      expect(response).to have_http_status(:ok)
      expect(event.reload.localized_content).to eq("zh-Hant" => { "title" => "日落節", "description" => "請帶椅子" },
        "tl" => { "title" => "Pista" })
      expect(response.parsed_body).to include("translation_status" => "untranslated", "automatic_translation_available" => false,
        "localized_content_stale" => {})

      patch "/api/v1/organizer/events/#{event.id}", headers: headers, params: { title: "Sunrise Fiesta" }
      expect(response.parsed_body["localized_content_stale"]).to eq("zh-Hant" => ["title"], "tl" => ["title"])
    end

    it "refuses retranslation until General Translation is configured" do
      post "/api/v1/organizer/events/#{event.id}/retranslate", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("code" => "unavailable",
        "error" => "Automatic translation is not available right now. Buyers see your English text.")
    end

    it "queues a forced retranslation of the event and its ticket types" do
      with_gt_credentials

      expect { post "/api/v1/organizer/events/#{event.id}/retranslate", headers: headers }
        .to have_enqueued_job(TranslateRecordJob).with("Event", event.id, nil, true)
        .and have_enqueued_job(TranslateRecordJob).with("TicketType", ticket_type.id, nil, true)
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq("translation_status" => "pending")
    end

    it "rejects repeat requests for a few minutes and drafts entirely" do
      with_gt_credentials
      post "/api/v1/organizer/events/#{event.id}/retranslate", headers: headers
      expect(response).to have_http_status(:accepted)

      expect { post "/api/v1/organizer/events/#{event.id}/retranslate", headers: headers }
        .not_to have_enqueued_job(TranslateRecordJob)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["code"]).to eq("recently_requested")

      travel_to(6.minutes.from_now) do
        event.update_column(:translation_status, "translated")
        post "/api/v1/organizer/events/#{event.id}/retranslate", headers: headers
        expect(response).to have_http_status(:accepted)
      end

      draft = create(:event, organizer_profile: organizer_profile)
      post "/api/v1/organizer/events/#{draft.id}/retranslate", headers: headers
      expect(response.parsed_body["code"]).to eq("not_public")
    end

    it "does not let another organization retranslate the event" do
      other = create(:user, :organizer)
      create(:organizer_profile, user: other)
      with_gt_credentials

      expect { post "/api/v1/organizer/events/#{event.id}/retranslate", headers: auth_headers(other) }
        .not_to have_enqueued_job(TranslateRecordJob)
      expect(response).to have_http_status(:not_found)
    end

    it "lets a platform admin retranslate any event" do
      with_gt_credentials

      expect { post "/api/v1/admin/events/#{event.id}/retranslate", headers: auth_headers(create(:user, :admin)) }
        .to have_enqueued_job(TranslateRecordJob).with("Event", event.id, nil, true)
      expect(response).to have_http_status(:accepted)

      post "/api/v1/admin/events/#{event.id}/retranslate", headers: auth_headers(organizer)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "remembering the buyer's language" do
    before { with_locales_enabled }

    it "stores the checkout language on the order" do
      free = create(:ticket_type, event: event, name: "Free", price_cents: 0, quantity_available: 10)
      post "/api/v1/orders", headers: { "Content-Type" => "application/json", "Accept-Language" => "ja-JP" },
        params: { event_id: event.id, buyer_email: "buyer@example.com", buyer_name: "Kenji", terms_accepted: true,
          terms_version: PolicyRegistry.buyer_terms[:version], line_items: [{ ticket_type_id: free.id, quantity: 1 }] }.to_json

      expect(response).to have_http_status(:created)
      expect(Order.find(response.parsed_body["id"]).locale).to eq("ja")
    end

    it "stores the language on waitlist entries and ticket transfers" do
      post "/api/v1/events/#{event.slug}/waitlist", headers: { "Accept-Language" => "ko" },
        params: { email: "fan@example.com", name: "Fan", quantity: 1, ticket_type_id: ticket_type.id }
      expect(WaitlistEntry.find_by!(email: "fan@example.com").locale).to eq("ko")

      owner = create(:user)
      order = create(:order, event: event, user: owner, buyer_email: owner.email)
      ticket = create(:ticket, order: order, event: event, ticket_type: ticket_type,
        order_item: create(:order_item, order: order, ticket_type: ticket_type))
      allow(EmailService).to receive(:send_ticket_transfer_async)
      post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer", params: { recipient_email: "friend@example.com" },
        headers: auth_headers(owner).merge("Accept-Language" => "zh-CN")
      expect(response).to have_http_status(:created)
      expect(TicketTransfer.find(response.parsed_body["id"]).locale).to eq("zh")
    end
  end
end
