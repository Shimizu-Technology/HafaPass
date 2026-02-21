require "rails_helper"

RSpec.describe "Sitemaps", type: :request do
  describe "GET /sitemap.xml" do
    it "returns XML with static pages" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("xml")
      expect(response.body).to include("https://hafapass.netlify.app/")
      expect(response.body).to include("https://hafapass.netlify.app/events")
    end

    it "includes published events" do
      event = create(:event, :published, title: "Test Concert")

      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://hafapass.netlify.app/events/#{event.slug}")
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
