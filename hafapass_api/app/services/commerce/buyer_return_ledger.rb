# frozen_string_literal: true

module Commerce
  # The gross buyer-owed ledger of one never-fulfilled capture
  # (docs/design/never-fulfilled-captures.md §5.4, §6.1).
  #
  # Pure arithmetic lives in the class methods and is shared by the writer
  # (Commerce::BuyerReturnPostings) and recomputation after a reversal:
  #
  #   applied_k = min(gross_k, C - A_(k-1))   excess_k = gross_k - applied_k
  #
  # Owed, applied, excess and every repayment amount depend only on gross
  # amounts and the frozen sequence, never on the allocation policy (P9). The
  # policy only splits applied money into the capture's components K.
  class BuyerReturnLedger
    # One movement in processing order. refund_split: the refund's own
    # RefundItem components when they cover its whole gross amount.
    Fact = Struct.new(:kind, :gross_cents, :refund_split, keyword_init: true)
    Step = Struct.new(:applied_cents, :excess_cents, :components, :allocation_method, keyword_init: true)
    State = Struct.new(:applied_cents, :components) do
      def self.zero(width)
        new(0, Array.new(width, 0))
      end
    end

    class << self
      # Allocates the next positive movement against what is already posted.
      def step(state, fact, captured_cents:, components:, policy:)
        gross = fact.gross_cents
        raise ArgumentError, "a forward movement needs a positive gross amount" unless gross.positive?

        applied = [gross, captured_cents - state.applied_cents].min
        remaining = components.zip(state.components).map { |total, posted| total - posted }
        split, method = split_for(fact, applied, remaining, state, components, policy)
        next_state = State.new(state.applied_cents + applied, state.components.zip(split).map(&:sum))
        [Step.new(applied_cents: applied, excess_cents: gross - applied, components: split, allocation_method: method),
          next_state]
      end

      # Folds the surviving facts in their frozen order (§5.4 reversal, step 2).
      def recompute(facts, captured_cents:, components:, policy:)
        facts.reduce(State.zero(components.length)) do |state, fact|
          step(state, fact, captured_cents: captured_cents, components: components, policy: policy).last
        end
      end

      private

      def split_for(fact, applied, remaining, state, components, policy)
        return [Array.new(remaining.length, 0), "bounded"] if applied.zero?

        case policy.to_s
        when "item_record"
          split = fact.refund_split
          if split && applied == fact.gross_cents && split.sum == applied &&
              split.zip(remaining).all? { |part, left| part.between?(0, left) }
            [split, "refund_items"]
          else
            [BoundedAllocator.call(applied, remaining), "bounded"]
          end
        when "cumulative_pro_rata"
          target = BoundedAllocator.call(state.applied_cents + applied, components)
          delta = target.zip(state.components).map { |goal, posted| goal - posted }
          # Cumulative targets can move a cent backwards between shares; never
          # post a negative share for a forward movement.
          if delta.all? { |part| !part.negative? }
            [delta, "cumulative_pro_rata"]
          else
            [BoundedAllocator.call(applied, remaining), "bounded"]
          end
        else
          raise ArgumentError, "unknown allocation policy #{policy}"
        end
      end
    end

    def self.for(capture)
      new(capture)
    end

    attr_reader :capture

    def initialize(capture)
      @capture = capture
    end

    def postings
      @postings ||= capture.buyer_return_postings.in_sequence.to_a
    end

    def captured_cents
      capture.captured_cents
    end

    def applied_cents
      postings.sum(&:applied_cents)
    end

    def excess_cents
      postings.sum(&:excess_cents)
    end

    def gross_returned_cents
      postings.sum(&:gross_cents)
    end

    # O = C - sum(applied) (§6.1).
    def owed_cents
      captured_cents - applied_cents
    end

    def returned_components
      BuyerReturnPosting::COMPONENTS.map { |column| postings.sum { |posting| posting.public_send(column) } }
    end

    def remaining_components
      capture.components.zip(returned_components).map { |total, returned| total - returned }
    end

    def state
      State.new(applied_cents, returned_components)
    end

    # The parts of "in flight" this tranche can see. Tranche 4 adds unreplayed
    # provider evidence and repayment operations to compute "available".
    def pending_refund_cents
      capture.payment.refunds.pending.sum(:amount_cents)
    end

    def open_dispute_cents
      Dispute.open.where(payment_id: capture.payment_id).sum(:amount_cents)
    end
  end
end
