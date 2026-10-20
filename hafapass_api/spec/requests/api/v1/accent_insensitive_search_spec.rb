require "rails_helper"

RSpec.describe "Accent-insensitive search", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:venue) { create(:venue, name: "Humåtak Bay Pavilion", village: "Humåtak") }
  let!(:hafa) { create(:event, :published, organizer_profile: organizer_profile, title: "Håfa Adai Night") }
  let!(:humatak) do
    create(:event, :published, organizer_profile: organizer_profile, title: "Sunset Market",
      venue: venue, venue_name: venue.name, venue_city: "Humåtak")
  end
  let!(:other) { create(:event, :published, organizer_profile: organizer_profile, title: "Tumon Run") }

  before { [hafa, humatak, other].each { |event| create(:ticket_type, event: event) } }

  def event_ids
    response.parsed_body["events"].pluck("id")
  end

  it "finds public events and village filters without the accent" do
    get "/api/v1/events", params: { q: "hafa" }
    expect(event_ids).to contain_exactly(hafa.id)

    get "/api/v1/events", params: { q: "humatak" }
    expect(event_ids).to contain_exactly(humatak.id)

    get "/api/v1/events", params: { village: "humatak" }
    expect(event_ids).to contain_exactly(humatak.id)
  end

  it "finds plain public text from accented input" do
    plain = create(:event, :published, organizer_profile: organizer_profile, title: "Hafa Pass Launch")
    create(:ticket_type, event: plain)

    get "/api/v1/events", params: { q: "Håfa" }

    expect(event_ids).to contain_exactly(hafa.id, plain.id)
  end

  it "filters public venues by village without the accent" do
    get "/api/v1/venues", params: { village: "humatak" }

    expect(response.parsed_body["venues"].pluck("id")).to eq([venue.id])
  end

  it "searches the organizer dashboard without the accent and still matches event IDs" do
    get "/api/v1/organizer/events", params: { q: "hafa" }, headers: auth_headers(user)
    expect(event_ids).to contain_exactly(hafa.id)

    get "/api/v1/organizer/events", params: { q: "humatak" }, headers: auth_headers(user)
    expect(event_ids).to contain_exactly(humatak.id)

    get "/api/v1/organizer/events", params: { q: other.id.to_s }, headers: auth_headers(user)
    expect(event_ids).to contain_exactly(other.id)
  end

  context "as a platform admin" do
    let(:admin) { create(:user, :admin) }

    it "searches events and users without the accent" do
      get "/api/v1/admin/events", params: { search: "hafa" }, headers: auth_headers(admin)
      expect(event_ids).to contain_exactly(hafa.id)

      person = create(:user, first_name: "Jåse", last_name: "Humåtak")
      get "/api/v1/admin/users", params: { search: "humatak" }, headers: auth_headers(admin)
      expect(response.parsed_body["users"].pluck("id")).to eq([person.id])
    end
  end
end
