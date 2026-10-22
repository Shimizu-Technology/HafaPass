# frozen_string_literal: true

# Freeze the part of each sale line funded by a particular payout. Historical
# payouts without rows use the same calculation from their frozen settlement.
class PayoutLineAllocator
  def self.amounts_for(payout)
    items = payout.settlement.settlement_items
    lines = items.where(kind: "sale_proceeds", source_type: "OrderItem")
      .where.not(source_id: nil).where("amount_cents > 0").order(:id).to_a
    return {} if lines.empty?

    offsets = Hash.new(0)
    refunds = items.where(kind: "refund", source_type: "RefundItem").where.not(source_id: nil).to_a
    refund_lines = RefundItem.where(id: refunds.map(&:source_id)).pluck(:id, :order_item_id).to_h
    refunds.each { |refund| offsets[refund_lines[refund.source_id]] += refund.amount_cents if refund_lines[refund.source_id] }
    items.where(kind: "adjustment", source_type: "OrderItem").where.not(source_id: nil).each do |adjustment|
      offsets[adjustment.source_id] += adjustment.amount_cents if adjustment.metadata["cash_custodian"] == "organizer"
    end
    weights = lines.map { |line| [line, [line.amount_cents + offsets[line.source_id], 0].max] }
    total = weights.sum(&:last)
    return {} if total.zero?

    funded = [payout.amount_cents, total].min
    shares = weights.map do |line, weight|
      numerator = funded * weight
      { id: line.source_id, cents: numerator / total, remainder: numerator % total }
    end
    (funded - shares.sum { |share| share[:cents] }).times do
      share = shares.max_by { |candidate| [candidate[:remainder], -candidate[:id]] }
      share[:cents] += 1
      share[:remainder] = -1
    end
    shares.to_h { |share| [share[:id], share[:cents]] }
  end

  def self.record!(payout)
    amounts_for(payout).each do |item_id, cents|
      payout.payout_line_allocations.create!(order_item_id: item_id, amount_cents: cents)
    end
  end

  def self.paid_for(payout, item_id)
    if payout.payout_line_allocations.exists?
      payout.payout_line_allocations.find_by(order_item_id: item_id)&.amount_cents.to_i
    else
      amounts_for(payout).fetch(item_id, 0)
    end
  end
end
