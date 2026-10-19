# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer attendee ticket resend", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event, buyer_email: "buyer@example.com") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type) }
  let(:path) { "/api/v1/organizer/events/#{event.id}/attendees/#{ticket.id}/resend" }

  def headers_for(user)
    auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async) do |resent_order, **options|
      create(:message_delivery, order: resent_order, template: options.fetch(:template))
    end
  end

  it "queues the order's ticket email through the shared resender and audits it" do
    expect { post path, headers: headers_for(owner) }.to change(AuditLog.where(action: "order.fulfillment_resent"), :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include("recipient" => "buyer@example.com")
    expect(EmailService).to have_received(:send_order_confirmation_async)
      .with(order, requested_by: owner, template: "fulfillment_resend")
  end

  it "applies the resender's two-minute cooldown to repeated requests" do
    post path, headers: headers_for(owner)
    expect { post path, headers: headers_for(owner) }.not_to change(MessageDelivery, :count)

    expect(response).to have_http_status(:too_many_requests)
    expect(EmailService).to have_received(:send_order_confirmation_async).once
  end

  it "requires attendee management permission" do
    marketer = create(:user)
    create(:organization_membership, organization: organization, user: marketer, role: :marketer)

    post path, headers: headers_for(marketer)

    expect(response).to have_http_status(:forbidden)
    expect(EmailService).not_to have_received(:send_order_confirmation_async)
  end

  it "does not reach tickets from another event" do
    other_event = create(:event, :published, organizer_profile: profile)

    post "/api/v1/organizer/events/#{other_event.id}/attendees/#{ticket.id}/resend", headers: headers_for(owner)

    expect(response).to have_http_status(:not_found)
  end

  it "refuses cancelled and transferred-away tickets" do
    ticket.update!(status: :cancelled)
    post path, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)

    ticket.update!(status: :issued, holder_user: create(:user))
    post path, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("transferred")
    expect(EmailService).not_to have_received(:send_order_confirmation_async)
  end
end
