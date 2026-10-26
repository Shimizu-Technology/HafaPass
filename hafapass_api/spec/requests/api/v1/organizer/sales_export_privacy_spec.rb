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

  it "refuses a stored pre-update answer export without downloading or deleting its retained bytes" do
    actor = event.organizer_profile.user
    item = OrganizerSalesExportRequest.create!(event: event, actor_user: actor,
      filters: {}, columns: %w[notes_custom_answers], status: "ready",
      expires_at: 1.day.from_now, storage_key: "private/sales-exports/legacy.csv")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_object).and_yield("INTERNAL_ORDER_CASE_DETAILS")
    expect(client).not_to receive(:get_object)
    expect(S3Service).not_to receive(:delete_private_export!)

    get "#{base}/sales_exports/#{item.id}", headers: auth_headers(actor)
    expect(response).to have_http_status(:gone)
    expect(response.parsed_body.fetch("error")).to include("privacy update")
    expect(response.body).not_to include("INTERNAL_ORDER_CASE_DETAILS")
    expect(item.reload).to have_attributes(status: "ready", storage_key: "private/sales-exports/legacy.csv")

    get "#{base}/sales_exports", headers: auth_headers(actor)
    expect(response.parsed_body.fetch("exports")).to be_empty
  end

  it "generates a versioned safe artifact from an older queued request and serves its actual answer bytes" do
    actor = event.organizer_profile.user
    item = OrganizerSalesExportRequest.create!(event: event, actor_user: actor,
      filters: {}, columns: %w[notes_custom_answers], row_count: 1)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-private-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    stored_bytes = nil
    allow(client).to receive(:put_object) { |options| stored_bytes = options.fetch(:body).read }
    allow(client).to receive(:get_object) { |_options, &block| block.call(stored_bytes) }

    OrganizerSalesExportJob.perform_now(item.id)
    expect(item.reload).to be_privacy_safe_artifact
    expect(item.storage_key).to start_with("private/sales-exports/v2/#{event.organization_id}/#{item.id}-")
    get "#{base}/sales_exports/#{item.id}", headers: auth_headers(actor)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(stored_bytes)
    expect(response.body).to include("Registration answers", "Meal preference", "Vegetarian")
    expect(response.body).not_to include("INTERNAL_ORDER_CASE_DETAILS", "INTERNAL_TICKET_CASE_DETAILS")
  end
end
