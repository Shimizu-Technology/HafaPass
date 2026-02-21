require "rails_helper"

RSpec.describe "OG Meta Endpoints", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) do
    create(:event,
      title: "Beach Party 2026",
      slug: "beach-party-2026",
      description: "Join us for the biggest beach party on Guam!",
      cover_image_url: "https://example.com/beach.jpg",
      status: :published,
      organizer_profile: organizer_profile
    )
  end

  describe "GET /og/events/:slug" do
    it "returns HTML with OG meta tags for a published event" do
      get "/og/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/html")

      body = response.body
      expect(body).to include('og:title')
      expect(body).to include(event.title)
      expect(body).to include('og:description')
      expect(body).to include('og:image')
      expect(body).to include(event.cover_image_url)
      expect(body).to include('twitter:card')
      expect(body).to include('summary_large_image')
      expect(body).to include("hafapass.netlify.app/events/#{event.slug}")
    end

    it "returns 404 for non-existent event" do
      get "/og/events/nonexistent-event"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for draft events" do
      draft_event = create(:event, status: :draft, organizer_profile: organizer_profile)

      get "/og/events/#{draft_event.slug}"

      expect(response).to have_http_status(:not_found)
    end

    it "uses default OG image when event has no cover image" do
      event.update!(cover_image_url: nil)

      get "/og/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("og-default.jpg")
    end

    it "truncates description to 160 characters" do
      long_description = "A" * 300
      event.update!(description: long_description)

      get "/og/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      # The truncated description should be in the HTML
      expect(response.body).not_to include("A" * 300)
    end
  end
end
