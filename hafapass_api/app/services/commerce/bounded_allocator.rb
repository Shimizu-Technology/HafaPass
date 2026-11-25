# frozen_string_literal: true

module Commerce
  # Splits `total_cents` across `remaining` balances without exceeding any of
  # them (docs/design/never-fulfilled-captures.md §5.4). It takes
  # MoneyAllocator's floors and hands out the remainder cents in the same index
  # order, skipping a component already at its remaining balance. So it equals
  # MoneyAllocator whenever MoneyAllocator stays in bounds; plain
  # MoneyAllocator can put a remainder cent on a zero balance.
  class BoundedAllocator
    class OutOfBounds < ArgumentError; end

    def self.call(total_cents, remaining)
      balances = remaining.map { |value| Integer(value) }
      raise OutOfBounds, "remaining balances must be non-negative" if balances.any?(&:negative?)
      raise OutOfBounds, "amount must be between 0 and the remaining total" unless total_cents.between?(0, balances.sum)
      return Array.new(balances.length, 0) if total_cents.zero?

      weight_total = balances.sum
      allocation = balances.map { |balance| (total_cents * balance).div(weight_total) }
      left = total_cents - allocation.sum
      allocation.each_index do |index|
        break if left.zero?
        next unless allocation[index] < balances[index]

        allocation[index] += 1
        left -= 1
      end
      # Spare capacity always covers the remainder (design §5.4 proof, step 1).
      raise OutOfBounds, "allocation did not fit" unless left.zero?

      allocation
    end
  end
end
