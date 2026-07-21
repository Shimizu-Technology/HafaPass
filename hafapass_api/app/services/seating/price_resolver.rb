# frozen_string_literal: true

module Seating
  class PriceResolver
    def self.call(ticket_types:, at: Time.current)
      new(ticket_types: ticket_types, at: at).call
    end

    def initialize(ticket_types:, at:)
      @ticket_types = ticket_types.uniq(&:id)
      @at = at
    end

    def call
      tiers = PricingTier.where(ticket_type_id: ticket_types.map(&:id)).order(:position, :id).to_a
      tier_ids = tiers.map(&:id)
      inventory = InventoryHold.active.where(pricing_tier_id: tier_ids).where("expires_at > ?", at)
        .group(:pricing_tier_id).sum(:quantity)
      waitlist = WaitlistOffer.offered.where(pricing_tier_id: tier_ids).where("expires_at > ?", at)
        .group(:pricing_tier_id).sum(:quantity)
      assigned = SeatHold.status_active.where(pricing_tier_id: tier_ids).joins(:seat_hold_session)
        .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
        .where("seat_hold_sessions.expires_at > ?", at).group(:pricing_tier_id).count
      tiers_by_ticket_type = tiers.group_by(&:ticket_type_id)

      ticket_types.to_h do |ticket_type|
        active = tiers_by_ticket_type.fetch(ticket_type.id, []).find do |tier|
          tier_active?(tier, inventory: inventory, waitlist: waitlist, assigned: assigned)
        end
        [ticket_type.id, active&.price_cents || ticket_type.price_cents]
      end
    end

    private

    attr_reader :ticket_types, :at

    def tier_active?(tier, inventory:, waitlist:, assigned:)
      if tier.quantity_based?
        tier.quantity_sold + inventory.fetch(tier.id, 0) + waitlist.fetch(tier.id, 0) +
          assigned.fetch(tier.id, 0) < tier.quantity_limit
      elsif tier.starts_at.present? && tier.ends_at.present?
        at.between?(tier.starts_at, tier.ends_at)
      elsif tier.starts_at.present?
        at >= tier.starts_at
      elsif tier.ends_at.present?
        at < tier.ends_at
      else
        false
      end
    end
  end
end
