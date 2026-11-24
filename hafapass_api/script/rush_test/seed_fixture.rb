# frozen_string_literal: true

# Seeds one rush fixture set (a free event and a paid event) into an ISOLATED copy.
#
#   cd hafapass_api            # on Render: the shell already starts in /app
#   HAFAPASS_RUSH_TARGET=<api host> bin/rails runner script/rush_test/seed_fixture.rb
#
# Safe by construction: it refuses unless the isolated-copy guard passes (staging env,
# HAFAPASS_RUSH_TARGET equal to this service's own host, database named *rush*staging*,
# no live Stripe keys) and the database holds nothing but [LOAD TEST] fixtures.
#
# Each run creates NEW events (labelled by RUSH_RUN_LABEL), so burst, ramp and repeat runs
# each start from untouched inventory without recreating the database.
#
# Optional environment: RUSH_RUN_LABEL (default: timestamp), FREE_CAPACITY (200),
# PAID_CAPACITY (200), PAYMENT_MODE (simulate | test; test needs the Stripe rehearsal
# configuration and is what makes paid_holds call Stripe's test API).
require "json"
require_relative "guard"

RushTest::Guard.check_environment!
RushTest::Guard.check_no_real_data!

label = ENV.fetch("RUSH_RUN_LABEL") { Time.now.utc.strftime("run-%m%d-%H%M%S") }
label = label.gsub(/[^A-Za-z0-9 _-]/, "")[0, 40]
free_capacity = Integer(ENV.fetch("FREE_CAPACITY", "200"))
paid_capacity = Integer(ENV.fetch("PAID_CAPACITY", "200"))
payment_mode = ENV.fetch("PAYMENT_MODE", "simulate")
abort "PAYMENT_MODE must be simulate or test" unless %w[simulate test].include?(payment_mode)
abort "PAYMENT_MODE=test needs HAFAPASS_PROVIDER_REHEARSAL=true with PROVIDER_REHEARSAL_SERVICES including stripe" if payment_mode == "test" && !ProviderRehearsal.stripe_enabled?
abort "FREE_CAPACITY and PAID_CAPACITY must be 1..5000" unless [free_capacity, paid_capacity].all? { |value| value.between?(1, 5000) }
abort "This run label already has fixtures; pick another RUSH_RUN_LABEL" if Event.where("title LIKE ?", "%#{label}").exists?

ActiveRecord::Base.transaction do
  SiteSetting.instance.update_columns(payment_mode: payment_mode)

  owner = User.find_or_create_by!(clerk_id: "rush_owner") do |user|
    user.email = "rush-owner@example.invalid"
    user.first_name = "Rush"
    user.last_name = "Owner"
    user.role = :organizer
  end
  org = Organization.find_by(slug: "rush-test-org") || Organization.create!(name: "Rush Test Org", timezone: "Pacific/Guam",
    currency: "usd", status: :active)
  profile = OrganizerProfile.find_by(organization: org) || OrganizerProfile.create!(user: owner, organization: org,
    business_name: "Rush Test", business_description: "Synthetic organizer for the hosted rush test")

  # Paid sales need a payout-ready organization: a ready manual account, certified (fictional)
  # tax information and an approved payment-readiness review. This mirrors the :connected_account
  # factory and holds only fictional values.
  if org.payout_connected_account_id.blank?
    account = ConnectedAccount.create!(organization: org, provider: "paypal", provider_account_id: "rush_merchant_#{SecureRandom.hex(4)}",
      status: :ready, charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [],
      country: "GU", currency: "usd")
    org.update!(payout_connected_account: account)
    OrganizerTaxInformation.create!(organization: org, legal_name: "Rush Test LLC", tax_classification: "llc_c", tin_type: "ein",
      tin: "012345678", mailing_address: "PO Box 1, Hagåtña, GU 96910", signer_name: "Rush Owner", certified_at: Time.current,
      certification_version: OrganizerTaxInformation::CERTIFICATION_VERSION)
    submitter = User.create!(clerk_id: "rush_admin_a", email: "rush-admin-a@example.invalid", first_name: "Rush", last_name: "AdminA", role: :admin)
    approver = User.create!(clerk_id: "rush_admin_b", email: "rush-admin-b@example.invalid", first_name: "Rush", last_name: "AdminB", role: :admin)
    snapshot = {
      evidence_reference: "rush-fixture/#{account.id}", evidence_digest: Digest::SHA256.hexdigest("rush-fixture-#{account.id}"),
      provider_approval_reference: "rush-fixture/approval", merchant_of_record: "organizer",
      fee_tax_schedule_reference: "rush-fixture-fee-tax", liability_schedule_reference: "rush-fixture-liability",
      controls: PaymentReadinessReview::CONTROL_KEYS.index_with(true), effective_at: 1.day.ago, expires_at: 1.year.from_now,
      provider_state_digest: account.readiness_state_digest
    }
    submission = PaymentReadinessReview.create!(connected_account: account, actor_user: submitter, decision: :submission, parent_review: nil, **snapshot)
    PaymentReadinessReview.create!(connected_account: account, actor_user: approver, decision: :approval, parent_review: submission, **snapshot)
  end

  base = { organizer_profile: profile, organization: org, description: "Hosted rush fixture", short_description: "rush",
           venue_name: "Rush Venue", venue_address: "1 Rush Rd", venue_city: "Hagatna", timezone: "Pacific/Guam",
           status: :published, published_at: Time.current, category: :sports, age_restriction: :all_ages }
  start = 9.days.from_now.change(hour: 19)
  times = { starts_at: start, ends_at: start + 3.hours, doors_open_at: start - 30.minutes }

  free_event = Event.create!(base.merge(times).merge(title: "[LOAD TEST] Copa Rush Free #{label}", max_capacity: free_capacity))
  free_type = TicketType.create!(event: free_event, name: "Free GA", description: "rush", price_cents: 0,
    quantity_available: free_capacity, max_per_order: 10)

  paid_event = Event.create!(base.merge(times).merge(title: "[LOAD TEST] Copa Rush Paid #{label}", max_capacity: paid_capacity))
  adult = TicketType.create!(event: paid_event, name: "Adult", description: "rush", price_cents: 1700,
    quantity_available: paid_capacity, max_per_order: 10)
  child = TicketType.create!(event: paid_event, name: "Child", description: "rush", price_cents: 1200,
    quantity_available: paid_capacity, max_per_order: 10)

  puts JSON.pretty_generate(
    label: label,
    payment_mode: payment_mode,
    k6_env: {
      ORG_SLUG: org.slug,
      EVENT_SLUG: free_event.slug, TICKET_TYPE_ID: free_type.id,
      PAID_EVENT_SLUG: paid_event.slug, PAID_TICKET_TYPE_ID: adult.id
    },
    consistency_env: { RUSH_EVENT_IDS: [free_event.id, paid_event.id].join(",") },
    capacity: { free: free_capacity, paid_adult: paid_capacity },
    other_ticket_types: { paid_child: child.id }
  )
end
