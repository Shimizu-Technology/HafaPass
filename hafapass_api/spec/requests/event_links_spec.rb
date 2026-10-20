require "rails_helper"

# Renaming an event (or giving it a new link name) must not break links that
# were already shared. Every public entry point resolves a retired link to the
# event and reports the current one.
RSpec.describe "Event links", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:organization) { organizer_profile.organization }
  let(:org_headers) { auth_headers(user).merge("X-Organization-Id" => organization.id.to_s) }
  let!(:event) do
    create(:event, :published, organizer_profile: organizer_profile, title: "Island Fest",
      starts_at: 5.days.from_now, published_at: 1.day.ago)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 100) }

  def member_headers(role)
    member = create(:user)
    create(:organization_membership, organization: organization, user: member, role: role)
    auth_headers(member).merge("X-Organization-Id" => organization.id.to_s)
  end

  describe "organizer edits" do
    it "keeps a published event's link when the title changes" do
      put "/api/v1/organizer/events/#{event.id}", params: { title: "Island Fest Returns" }, headers: org_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "island-fest", "slug_follows_title" => false,
        "ever_published" => true)
    end

    it "lets a draft's link follow the title" do
      draft = create(:event, organizer_profile: organizer_profile, title: "Draft Night")

      put "/api/v1/organizer/events/#{draft.id}", params: { title: "Better Night" }, headers: org_headers, as: :json

      expect(response.parsed_body).to include("slug" => "better-night", "slug_follows_title" => true)
    end

    it "sets a custom link and keeps the old one as a redirect" do
      put "/api/v1/organizer/events/#{event.id}", params: { slug: "island-fest-2026" }, headers: org_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "island-fest-2026", "custom_slug" => true)
      expect(event.reload.slug_redirects.pluck(:slug)).to eq(["island-fest"])
    end

    it "lets marketers, who can edit event content, set the link" do
      put "/api/v1/organizer/events/#{event.id}", params: { slug: "island-fest-live" },
        headers: member_headers(:marketer), as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload.slug).to eq("island-fest-live")
    end

    it "explains a rejected link and keeps the current one" do
      put "/api/v1/organizer/events/#{event.id}", params: { slug: "checkout" }, headers: org_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Event link is reserved. Choose a different link name")
      expect(event.reload.slug).to eq("island-fest")
    end

    it "ignores an empty link field" do
      put "/api/v1/organizer/events/#{event.id}", params: { slug: "" }, headers: org_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload.slug).to eq("island-fest")
    end

    context "when another save takes the link name between the check and the write" do
      # Both saves passed the availability check; the unique index rejects the second.
      before do
        create(:event, :published, title: "Rival Fest").update_columns(slug: "island-fest-2026")
        allow(Event).to receive(:public_slug_problem).and_return(nil)
      end

      it "returns the inline link error on update instead of a server error" do
        put "/api/v1/organizer/events/#{event.id}", params: { slug: "island-fest-2026" }, headers: org_headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("errors" => ["Event link is already used by another event"])
        expect(event.reload.slug).to eq("island-fest")
        expect(event.slug_redirects).to be_empty
      end

      it "returns the inline link error on create" do
        post "/api/v1/organizer/events", params: { title: "New Fest", slug: "island-fest-2026", venue_name: "Hall",
          starts_at: 9.days.from_now.iso8601 }, headers: org_headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("errors" => ["Event link is already used by another event"])
      end
    end

    it "checks link availability with the same rules as saving" do
      other = create(:event, :published, title: "Other Fest")
      other.update!(slug: "other-fest-2026")

      get "/api/v1/organizer/events/#{event.id}/slug_availability", params: { slug: "Other-Fest" }, headers: org_headers

      expect(response.parsed_body).to eq("slug" => "other-fest", "available" => false,
        "message" => "Event link is already used by another event")

      get "/api/v1/organizer/events/#{event.id}/slug_availability", params: { slug: "island-fest" }, headers: org_headers
      expect(response.parsed_body).to include("available" => true)

      get "/api/v1/organizer/events/#{event.id}/slug_availability", params: { slug: "new" }, headers: org_headers
      expect(response.parsed_body).to include("available" => false,
        "message" => "Event link is reserved. Choose a different link name")
    end

    it "does not let staff without content access check links" do
      get "/api/v1/organizer/events/#{event.id}/slug_availability", params: { slug: "anything" },
        headers: member_headers(:scanner)

      expect(response).to have_http_status(:forbidden)
    end
  end

  context "after the link changes" do
    before { event.update!(slug: "island-fest-2026") }

    it "resolves the old link on the public event page and reports the current one" do
      get "/api/v1/events/island-fest"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("id" => event.id, "slug" => "island-fest-2026",
        "redirected_from" => "island-fest")
    end

    it "resolves a hand-typed link in the wrong case and reports the canonical one" do
      get "/api/v1/events/Island-Fest-2026"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "island-fest-2026", "redirected_from" => "Island-Fest-2026")

      get "/api/v1/events/ISLAND-FEST"
      expect(response.parsed_body).to include("slug" => "island-fest-2026", "redirected_from" => "ISLAND-FEST")

      get "/og/events/Island-Fest"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('og:url" content="https://hafapass.com/events/island-fest-2026"')
    end

    it "does not mark a request with the current link as a redirect" do
      get "/api/v1/events/island-fest-2026"

      expect(response.parsed_body).not_to have_key("redirected_from")
    end

    it "resolves the old link for an organizer preview" do
      get "/api/v1/events/island-fest?preview=true", headers: auth_headers(user)

      expect(response.parsed_body).to include("slug" => "island-fest-2026", "redirected_from" => "island-fest")
    end

    it "keeps hidden events hidden behind their old links" do
      event.update_columns(status: Event.statuses[:draft])

      get "/api/v1/events/island-fest"

      expect(response).to have_http_status(:not_found)
    end

    it "resolves the old link for waitlist management" do
      entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, email: "fan@example.com")

      get "/api/v1/events/island-fest/waitlist/status", params: { management_token: entry.management_credential }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].length).to eq(1)
    end

    it "resolves the old link for seating" do
      get "/api/v1/events/island-fest/seating"

      expect(response.parsed_body["error"]).to eq("Assigned seating is not active")
    end

    it "serves crawler previews of the old link with the current URL" do
      get "/og/events/island-fest"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<link rel="canonical" href="https://hafapass.com/events/island-fest-2026" />')
      expect(response.body).to include('og:url" content="https://hafapass.com/events/island-fest-2026"')
      expect(response.body).not_to include("/events/island-fest\"")
    end

    it "lists only the current link in the sitemap" do
      get "/sitemap.xml"

      expect(response.body).to include("https://hafapass.com/events/island-fest-2026<")
      expect(response.body).not_to include("https://hafapass.com/events/island-fest<")
    end

    it "keeps an unknown link a 404" do
      get "/api/v1/events/never-existed"

      expect(response).to have_http_status(:not_found)
      get "/og/events/never-existed"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "venue links" do
    it "reports a lost race for a venue link name as a validation error" do
      admin_headers = auth_headers(create(:user, role: :admin))
      venue = create(:venue, name: "Tumon Hall", slug: nil)
      create(:venue, slug: "tumon-grand-hall")
      allow(Venue).to receive(:public_slug_problem).and_return(nil)

      put "/api/v1/admin/venues/#{venue.id}", params: { slug: "tumon-grand-hall" }, headers: admin_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("errors" => ["Venue link is already used by another venue"])
    end

    it "resolves a retired venue link and reports the current one" do
      venue = create(:venue, name: "Tumon Hall", slug: nil)
      venue.update!(slug: "tumon-grand-hall")

      get "/api/v1/venues/tumon-hall"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "tumon-grand-hall", "redirected_from" => "tumon-hall")

      get "/api/v1/venues/tumon-grand-hall"
      expect(response.parsed_body).not_to have_key("redirected_from")
    end
  end
end
