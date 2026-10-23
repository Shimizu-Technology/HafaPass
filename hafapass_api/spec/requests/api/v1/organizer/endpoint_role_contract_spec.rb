# frozen_string_literal: true

require "rails_helper"

# An independent public contract, deliberately hard-coded rather than generated
# from OrganizationAuthorization (including its assignment permission matrix).
# Exercise real routing, authentication, selected-org scoping and authorization.
RSpec.describe "Organizer endpoint-by-role contract", type: :request do
  CONTRACT = {
    owner: %i[view create edit publish content cancel clone recurrence inventory prices seating attendees search crm finance_export
      guests waitlist resend door scan undo refunds reports settlements payouts payout_settings tax_settings
      invite remove role transfer staff promo promoters campaigns organization profile verification activity],
    manager: %i[view create edit publish content clone recurrence inventory prices seating attendees search crm finance_export
      guests waitlist resend door scan undo reports staff promo promoters campaigns activity],
    finance: %i[view attendees finance_export refunds reports settlements payouts activity],
    marketer: %i[view content promo promoters campaigns],
    box_office_assigned: %i[view attendees search crm guests waitlist resend door scan undo],
    box_office_unassigned: [],
    scanner_assigned: %i[view search scan],
    scanner_unassigned: [],
    event_manager: %i[view edit publish content inventory prices seating attendees search crm finance_export
      guests waitlist resend door scan undo reports staff promo promoters campaigns activity]
  }.freeze

  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, event: event, ticket_type: type, order: order) }
  let(:other_member) { create(:organization_membership, organization: organization, role: :scanner) }
  let(:actor) { create(:user) }
  let(:headers) { auth_headers(actor).merge("X-Organization-Id" => organization.id.to_s) }

  # Each successful write uses isolated transactional fixtures. Refund/payout
  # probes intentionally omit Idempotency-Key and stop at the command's own
  # validation, before any money can move. Publish probes an already published
  # event. Their exact expected statuses still prove the role gate was passed.
  def probe(capability, selected_event = event)
    path = "/api/v1/organizer/events/#{selected_event.id}"
    case capability
    when :activity then get "/api/v1/organizer/activity_logs", params: { event_id: selected_event.id }, headers: headers
    when :view then get path, headers: headers
    when :create then post "/api/v1/organizer/events", params: { title: "Contract draft" }, headers: headers
    when :edit then patch path, params: { max_capacity: 600 }, headers: headers
    when :content then patch path, params: { description: "Contract content" }, headers: headers
    when :publish then post "#{path}/publish", headers: headers
    when :cancel then post "#{path}/cancel", params: { reason: "Contract cancellation", refund_count: 0, refund_total_cents: 0 }, headers: headers
    when :clone then post "#{path}/clone", headers: headers
    when :recurrence then post "#{path}/generate_recurrences", headers: headers
    when :prices then get "#{path}/ticket_types/#{type.id}/pricing_tiers", headers: headers
    when :inventory then get "#{path}/ticket_types", headers: headers
    when :seating then get "#{path}/seating", headers: headers
    when :attendees then get "#{path}/attendees", headers: headers
    when :search then get "#{path}/admissions/search", params: { q: "Guest" }, headers: headers
    when :crm then get "#{path}/crm/export", headers: headers
    when :finance_export then get "#{path}/finance/orders_export", headers: headers
    when :guests then get "#{path}/guest_list", headers: headers
    when :waitlist then get "#{path}/waitlist", headers: headers
    when :resend then post "#{path}/attendees/#{ticket.id}/resend", headers: headers
    when :door then get "#{path}/box_office/summary", headers: headers
    when :scan
      device = create(:scanner_device, event: selected_event, user: actor)
      get "#{path}/scanner_devices/#{device.id}/manifest", headers: headers
    when :undo
      ticket.update!(status: :checked_in, checked_in_at: Time.current, first_admitted_at: Time.current)
      device = create(:scanner_device, event: selected_event, user: actor)
      admission = create(:admission_action, event: selected_event, organization: selected_event.organization, scanner_device: device, ticket: ticket,
        sequence: 1, actor_user: actor)
      post "#{path}/scanner_devices/#{device.id}/sync", params: { actions: [{ action_uuid: SecureRandom.uuid,
        sequence: 2, manifest_version: 1, occurred_at: Time.current.iso8601, kind: "reverse", source: "online",
        reverses_action_uuid: admission.action_uuid }] }, headers: headers
    when :refunds then post "#{path}/orders/#{order.id}/refund", headers: headers
    when :reports then get "#{path}/finance", headers: headers
    when :settlements then post "#{path}/finance/finalize", headers: headers
    when :payouts then post "#{path}/finance/payout", headers: headers
    when :payout_settings then get "/api/v1/organizer/connected_accounts", headers: headers
    when :tax_settings then get "/api/v1/organizer/tax_information", headers: headers
    when :invite then post "/api/v1/organizer/memberships", params: { email: "contract+door@example.com", role: "scanner" }, headers: headers
    when :remove then delete "/api/v1/organizer/memberships/#{other_member.id}", headers: headers
    when :role then patch "/api/v1/organizer/memberships/#{other_member.id}", params: { role: "box_office" }, headers: headers
    when :transfer then post "/api/v1/organizer/memberships/#{other_member.id}/transfer_ownership", headers: headers
    when :staff then get "#{path}/staff_assignments", headers: headers
    when :promo then get "#{path}/promo_codes", headers: headers
    when :promoters then get "#{path}/promoters", headers: headers
    when :campaigns then get "#{path}/communication_campaigns", headers: headers
    when :organization then patch "/api/v1/organizer/organization", params: { organization: { marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910", certified: true } }, headers: headers
    when :profile then put "/api/v1/organizer_profile", params: { business_description: "Contract description" }, headers: headers
    when :verification then post "/api/v1/organizer_profile/submit_verification", headers: headers
    else raise "Unknown contract capability #{capability}"
    end
  end

  CONTRACT.each do |role, allowed|
    context role.to_s do
      before do
        organization
        allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([])
        membership_role = role.to_s.sub(/_(assigned|unassigned)$/, '')
        membership_role = "marketer" if role == :event_manager
        if role == :owner
          organization.organization_memberships.find_by!(user: profile.user).update!(role: :manager)
        end
        create(:organization_membership, organization: organization, user: actor, role: membership_role)
        if role.to_s.end_with?("_assigned") || role == :event_manager
          assignment_role = role == :event_manager ? :manager : membership_role
          create(:event_staff_assignment, event: event, user: actor, role: assignment_role)
        end
      end

      it "pins explicit activity permission expectations independently" do
        expected = {
          owner: [true, true, true], manager: [false, true, false], finance: [false, false, true],
          marketer: [false, false, false], box_office_assigned: [false, false, false], box_office_unassigned: [false, false, false],
          scanner_assigned: [false, false, false], scanner_unassigned: [false, false, false], event_manager: [false, true, false]
        }.fetch(role)
        actual = %i[view_activity_all view_activity_events view_activity_finance].map do |permission|
          OrganizationAuthorization.allowed?(user: actor, organization: organization, event: event, permission: permission)
        end
        expect(actual).to eq(expected)
      end

      CONTRACT.fetch(:owner).each do |capability|
        it "#{allowed.include?(capability) ? 'allows' : 'denies'} #{capability}" do
          probe(capability)
          if capability == :undo
            if !allowed.include?(:scan)
              expect(response).to have_http_status(:unprocessable_entity)
              expect(response.parsed_body.fetch("error")).to include("no longer active")
            else
              expect(response).to have_http_status(:ok), response.body
              expected = allowed.include?(:undo) ? "accepted" : "rejected"
              expect(response.parsed_body.dig("results", 0, "result")).to eq(expected)
              expect(ticket.reload.checked_in?).to eq(!allowed.include?(:undo))
            end
          elsif capability == :edit && role == :marketer
            expect(response).to have_http_status(:ok)
            expect(event.reload.max_capacity).to eq(500)
          elsif allowed.include?(capability)
            status = { create: 201, clone: 201, invite: 201, remove: 204, resend: 202,
              refunds: 422, payouts: 422, publish: 422, recurrence: 422, settlements: 422, verification: 422 }.fetch(capability, 200)
            expect(response.status).to eq(status), "#{capability}: #{response.body}"
            expect(event.reload.max_capacity).to eq(600) if capability == :edit
          else
            expect(response).to have_http_status(:forbidden), "#{capability}: #{response.body}"
          end
        end
      end

      %i[view content inventory prices seating attendees search crm finance_export guests waitlist door scan refunds reports staff promo promoters campaigns clone].each do |capability|
        it "rejects #{capability} IDs from another organization even when also a member there" do
          foreign_event = create(:event, :published)
          create(:organization_membership, organization: foreign_event.organization, user: actor, role: :owner)
          probe(capability, foreign_event)
          expect(response).to have_http_status(:not_found), response.body
        end
      end
    end
  end
end
