require "rails_helper"

RSpec.describe "Sitemaps", type: :request do
  describe "GET /sitemap.xml" do
    it "returns XML with static pages" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("xml")
      expect(response.body).to include("https://hafapass.com/")
      expect(response.body).to include("https://hafapass.com/events")
    end

    it "includes published events" do
      event = create(:event, :published, title: "Test Concert")
      create(:ticket_type, event: event)

      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://hafapass.com/events/#{event.slug}")
    end

    it "includes upcoming published events even when tickets are sold out" do
      event = create(:event, :published, title: "Sold Out Concert")
      create(:ticket_type, :sold_out, event: event)

      get "/sitemap.xml"

      expect(response.body).to include("https://hafapass.com/events/#{event.slug}")
    end

    it "does not include ended published events" do
      event = create(:event, :published, :past, title: "Past Concert")

      get "/sitemap.xml"

      expect(response.body).not_to include("https://hafapass.com/events/#{event.slug}")
    end

    it "does not include draft events" do
      draft_event = create(:event, title: "Draft Event", status: :draft)

      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(draft_event.slug)
    end

    it "does not require authentication" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
    end
  end
end
