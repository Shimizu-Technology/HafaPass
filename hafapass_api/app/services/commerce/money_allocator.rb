# frozen_string_literal: true

module Commerce
  class MoneyAllocator
    def self.call(total_cents, weights)
      return Array.new(weights.length, 0) if total_cents.zero? || weights.empty?

      weight_total = weights.sum
      return Array.new(weights.length, 0) if weight_total.zero?

      allocations = weights.map { |weight| (total_cents * weight).div(weight_total) }
      (total_cents - allocations.sum).times do |index|
        allocations[index % allocations.length] += 1
      end
      allocations
    end
  end
end
