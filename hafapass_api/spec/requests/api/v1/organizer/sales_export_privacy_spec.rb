require "rails_helper"
require "csv"

RSpec.describe "Organizer registration-answer export privacy", type: :request do
  let(:event) { create(:event, :published) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, event: event, order: order) }
  let(:support) { create(:user, role: :support) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }

  before do
    ticket
    SupportNote.create!(order: order, author_user: support, body: "INTERNAL_ORDER_CASE_DETAILS")
    SupportNote.create!(ticket: ticket, author_user: support, body: "INTERNAL_TICKET_CASE_DETAILS")
    question = create(:registration_question, event: event, prompt: "Meal preference")
    RegistrationResponse.create!(order: order, registration_question: question,
      prompt_snapshot: question.prompt, kind_snapshot: question.kind_before_type_cast,
      required_snapshot: true, answered_at: Time.current, answer: "Vegetarian")
  end

  %i[owner manager box_office].each do |role|
    %w[tickets orders].each do |view|
      it "exports registration answers without internal support bodies for #{role} in #{view} view" do
        actor = if role == :owner
          event.organizer_profile.user
        else
          create(:user).tap do |user|
            create(:organization_membership, organization: event.organization, user: user, role: role)
            create(:event_staff_assignment, event: event, user: user, role: :box_office) if role == :box_office
          end
        end

        get "/api/v1/support/notes", params: { order_id: order.id }, headers: auth_headers(actor)
        expect(response).to have_http_status(:forbidden)

        post "#{base}/sales_exports", params: { view: view, columns: %w[order_number notes_custom_answers] },
          headers: auth_headers(actor)
        expect(response).to have_http_status(:ok)
        expect(response.headers["Cache-Control"]).to include("no-store")
        csv = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
        expect(csv.headers).to eq(["Order #", "Registration answers"])
        expect(csv.first["Registration answers"]).to include("Meal preference", "Vegetarian")
        expect(response.body).not_to include("INTERNAL_ORDER_CASE_DETAILS", "INTERNAL_TICKET_CASE_DETAILS")
      end
    end
  end

  it "continues to deny registration answers to finance-only staff" do
    actor = create(:user)
    create(:organization_membership, organization: event.organization, user: actor, role: :finance)
    post "#{base}/sales_exports", params: { columns: %w[notes_custom_answers] }, headers: auth_headers(actor)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include("Vegetarian", "INTERNAL_ORDER_CASE_DETAILS")
  end

  it "does not expose answers or internal notes across organizations" do
    actor = create(:organizer_profile).user
    post "#{base}/sales_exports", params: { columns: %w[notes_custom_answers] }, headers: auth_headers(actor)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("Vegetarian", "INTERNAL_ORDER_CASE_DETAILS")
  end
end
