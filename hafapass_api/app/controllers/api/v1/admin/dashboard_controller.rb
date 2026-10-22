# frozen_string_literal: true

class Api::V1::Admin::DashboardController < Api::V1::Admin::BaseController
  SETUP_ITEMS = {
    "policy_register" => ["Production policy register", "Checkout is off until you approve the production policy register."],
    "resend_production" => ["Production email (Resend)",
      "Ticket and order emails are off until you approve production email."]
  }.freeze

  # GET /api/v1/admin/dashboard
  def show
    financials = Commerce::LedgerTotals.call(Order.where(status: [:completed, :partially_refunded, :refunded]))
    render json: {
      total_events: Event.group(:status).count,
      total_users: User.group(:role).count,
      total_orders: Order.count,
      total_revenue_cents: financials[:net_cents],
      financials: financials,
      # financials.fee_cents sums every fee component, including actual card
      # processing; platform_revenue separates HåfaPass fee revenue from it.
      platform_revenue: Commerce::PlatformRevenue.call,
      open_disputes: Dispute.open.count,
      payouts_needing_reconciliation: Payout.where(status: [:pending, :processing, :held]).count,
      open_reconciliation_exceptions: ReconciliationException.open.count,
      operational_signals: SystemReadiness.call.dig(:checks, :operations),
      total_tickets_sold: Ticket.where(status: [:issued, :checked_in]).count,
      recent_events: recent_events_json,
      recent_orders: recent_orders_json,
      setup_required: setup_required_json,
      organizers_awaiting_verification: organizers_awaiting_verification_json,
      verified_organizers: verified_organizers_json,
      suspended_organizers: suspended_organizers_json
    }
  end

  private

  # One-time production setup an admin approves with one click, plus a
  # warning when a current approval expires within 30 days.
  def setup_required_json
    return [] unless Rails.env.production?

    SETUP_ITEMS.filter_map do |key, (label, message)|
      approval = PlatformCapabilities.active_approval(key)
      enabled = approval && PlatformCapabilities.configured?(key)
      expiring = enabled && PlatformCapabilities.expiring_soon?(approval)
      next if enabled && !expiring

      configured = PlatformCapabilities.configured?(key)
      missing = PlatformCapabilities.definition(key).fetch(:required_env).reject { |name| ENV[name].present? }
      help = configured ? nil : "Set #{missing.presence&.join(', ') || 'the provider settings'} on the API service first."
      blockers = key == "policy_register" ? PolicyRegistry.approval_blockers : []
      if blockers.any?
        configured = false
        help = "Fix the policy text first: #{blockers.join('; ')}"
      end
      draft = key == "policy_register" && PolicyRegistry.draft?
      if expiring
        message = "The #{label.downcase} approval expires on #{approval.expires_at.to_date.to_fs(:long)}. " \
          "Approve again before then to keep it on."
      end
      { key: key, label: label, message: message, configured: configured, help: help,
        expires_at: approval&.expires_at, expiring_soon: expiring ? true : false,
        requires_draft_acknowledgment: draft, acknowledgment_text: draft ? PolicyRegistry::DRAFT_ACKNOWLEDGMENT : nil }
    end
  end

  # Organizers whose events cannot sell in production until an admin verifies
  # them (one action on this dashboard). Requested ones first.
  def organizers_awaiting_verification_json
    OrganizerProfile.where(verification_status: %i[pending unverified rejected])
      .includes(:user, organization: { organization_memberships: :user })
      .order(Arel.sql("organizer_profiles.verification_requested_at IS NULL, " \
        "organizer_profiles.verification_requested_at, organizer_profiles.created_at"))
      .limit(100).map do |profile|
        owner = profile.organization.organization_memberships.find { |membership| membership.role == "owner" }&.user
        {
          profile_id: profile.id, business_name: profile.business_name, organization_id: profile.organization_id,
          owner_email: owner&.email || profile.user&.email, requested_at: profile.verification_requested_at,
          verification_status: profile.verification_status, payout_ready: profile.organization.payout_ready?,
          event_count: profile.events.count
        }
      end
  end

  # "Sales paused" organizers; resuming re-verifies them.
  def suspended_organizers_json
    OrganizerProfile.verification_status_suspended.includes(:user, organization: { organization_memberships: :user })
      .order(updated_at: :desc).limit(100).map do |profile|
        owner = profile.organization.organization_memberships.find { |membership| membership.role == "owner" }&.user
        { profile_id: profile.id, business_name: profile.business_name, owner_email: owner&.email || profile.user&.email,
          suspended_at: profile.updated_at, verification_notes: profile.verification_notes }
      end
  end

  def verified_organizers_json
    OrganizerProfile.verification_status_verified.includes(:verified_by_user)
      .order(verified_at: :desc).limit(50).map do |profile|
        { profile_id: profile.id, business_name: profile.business_name, verified_at: profile.verified_at,
          verified_by: profile.verified_by_user&.email }
      end
  end

  def recent_events_json
    Event.includes(:organizer_profile).order(created_at: :desc).limit(5).map do |e|
      {
        id: e.id,
        title: e.title,
        slug: e.slug,
        status: e.status,
        category: e.category,
        starts_at: e.starts_at,
        created_at: e.created_at,
        organizer_name: e.organizer_profile&.business_name
      }
    end
  end

  def recent_orders_json
    Order.includes(:event, :user).order(created_at: :desc).limit(10).map do |o|
      {
        id: o.id,
        buyer_name: o.buyer_name,
        buyer_email: o.buyer_email,
        total_cents: o.total_cents,
        status: o.status,
        event_title: o.event&.title,
        event_slug: o.event&.slug,
        created_at: o.created_at
      }
    end
  end
end
