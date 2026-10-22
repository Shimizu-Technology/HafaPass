# frozen_string_literal: true

# Read-only view of payment disputes recorded from provider webhooks.
class Api::V1::Admin::DisputesController < Api::V1::Admin::BaseController
  include AdminListing

  # GET /api/v1/admin/disputes
  def index
    scope = Dispute.joins(order: { event: :organization })
    scope = scope.where(events: { organization_id: params[:organization_id] }) if params[:organization_id].present?
    scope = scope.where(orders: { event_id: params[:event_id] }) if params[:event_id].present?
    if (term = search_term)
      pattern = like_pattern(term)
      scope = scope.where("disputes.provider_dispute_id ILIKE :q OR orders.buyer_email ILIKE :q OR orders.buyer_name ILIKE :q " \
        "OR events.title ILIKE :q OR organizations.name ILIKE :q OR CAST(orders.id AS text) = :id",
        q: pattern, id: term.delete_prefix("#"))
    end
    counts = scope.group(:status).count
    scope = scope.where(status: params[:status]) if Dispute.statuses.key?(params[:status].to_s)
    disputes, meta = admin_page(scope.includes(order: { event: :organization }).order("disputes.opened_at DESC, disputes.id DESC"))
    render json: {
      disputes: disputes.map { |dispute| dispute_json(dispute) },
      meta: meta,
      status_counts: Dispute.statuses.keys.index_with { |status| counts.fetch(status, 0) }
    }
  end

  private

  def dispute_json(dispute)
    order = dispute.order
    event = order.event
    dispute.attributes.slice(
      "id", "provider", "provider_dispute_id", "amount_cents", "currency", "status", "reason", "opened_at", "closed_at"
    ).merge(
      order: { id: order.id, buyer_name: order.buyer_name, buyer_email: order.buyer_email, total_cents: order.total_cents,
        status: order.status },
      event: { id: event.id, title: event.title, slug: event.slug },
      organization: { id: event.organization_id, name: event.organization.name }
    )
  end
end
