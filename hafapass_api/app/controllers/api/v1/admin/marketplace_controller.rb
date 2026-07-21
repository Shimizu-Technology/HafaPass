# frozen_string_literal: true

class Api::V1::Admin::MarketplaceController < Api::V1::Admin::BaseController
  def show
    upcoming = Event.published.where("COALESCE(events.ends_at, events.starts_at) > ?", Time.current)
    discoverable = Event.discoverable
    collection_ids = MarketplaceCollectionEvent.where(event_id: discoverable.select(:id))
      .select(:marketplace_collection_id)
    organizer_ids = discoverable.select(:organization_id)
    funnel = MarketplaceFunnelEvent.group(:stage).count
    purchases = MarketplaceFunnelEvent.purchase.count
    checkout_starts = MarketplaceFunnelEvent.checkout_started.count

    render json: {
      supply: {
        published_upcoming: upcoming.distinct.count,
        purchasable_upcoming: discoverable.count,
        sold_out_or_unavailable: upcoming.distinct.count - discoverable.count,
        empty_collections: MarketplaceCollection.published.where.not(id: collection_ids).count,
        organizers_without_upcoming_inventory: Organization.status_active.where.not(id: organizer_ids).count,
        categories_without_inventory: Event.categories.keys - discoverable.distinct.pluck(:category),
        villages_with_inventory: discoverable.where.not(venue_city: [nil, ""]).distinct.order(:venue_city).pluck(:venue_city)
      },
      funnel: funnel,
      checkout_conversion_percent: checkout_starts.positive? ? ((purchases.to_f / checkout_starts) * 100).round(1) : 0,
      attribution: attribution_rows
    }
  end

  private

  def attribution_rows
    AcquisitionAttribution.group(:source, :medium, :campaign).joins(:order)
      .where(orders: { status: [:completed, :partially_refunded, :refunded] })
      .pluck(:source, :medium, :campaign, Arel.sql("COUNT(acquisition_attributions.id)"),
        Arel.sql("COALESCE(SUM(orders.total_cents), 0)"))
      .map { |source, medium, campaign, orders, gross_order_value|
        { source: source, medium: medium, campaign: campaign, orders: orders,
          gross_order_value_cents: gross_order_value }
      }
  end
end
