# frozen_string_literal: true

require "rails_helper"

# Pure ledger arithmetic (docs/design/never-fulfilled-captures.md §5.4, §5.5;
# tests L-01, L-02, L-17, L-18, L-24). No database.
RSpec.describe Commerce::BuyerReturnLedger do
  def fact(**attributes)
    Commerce::BuyerReturnLedger::Fact.new(**attributes)
  end

  def run(facts, captured:, components:, policy: "item_record")
    state = described_class::State.zero(components.length)
    facts.map do |fact|
      step, state = described_class.step(state, fact, captured_cents: captured, components: components, policy: policy)
      [step.applied_cents, step.excess_cents, step.components]
    end
  end

  describe Commerce::BoundedAllocator do
    it "never exceeds a remaining balance and equals MoneyAllocator whenever MoneyAllocator stays in bounds (L-01)" do
      random = Random.new(2026_11_26)
      equal_cases = 0
      10_000.times do
        remaining = Array.new(4) { random.rand(3).zero? ? 0 : random.rand(0..3000) }
        next if remaining.sum.zero?

        amount = random.rand(0..remaining.sum)
        bounded = described_class.call(amount, remaining)
        expect(bounded.sum).to eq(amount)
        expect(bounded.zip(remaining)).to all(satisfy { |part, left| part.between?(0, left) })
        plain = Commerce::MoneyAllocator.call(amount, remaining)
        if plain.zip(remaining).all? { |part, left| part <= left }
          expect(bounded).to eq(plain)
          equal_cases += 1
        end
      end
      expect(equal_cases).to be > 5_000
    end

    it "keeps a remainder cent off a zero balance, where MoneyAllocator puts it" do
      expect(Commerce::MoneyAllocator.call(1, [0, 1, 1])).to eq([1, 0, 0])
      expect(described_class.call(1, [0, 1, 1])).to eq([0, 1, 0])
      expect(described_class.call(1, [0, 0, 0, 1])).to eq([0, 0, 0, 1])
    end

    it "refuses an amount above the remaining total or a negative balance" do
      expect { described_class.call(3, [1, 1]) }.to raise_error(described_class::OutOfBounds)
      expect { described_class.call(1, [2, -1]) }.to raise_error(described_class::OutOfBounds)
    end
  end

  it "decides excess on gross against the capture alone (E2, E3)" do
    # E2: K = (1200, 160); refund 470 with its own items (415, 55); lost dispute 891.
    e2 = run([fact(kind: "refund", gross_cents: 470, refund_split: [415, 55]),
      fact(kind: "dispute_loss", gross_cents: 891)], captured: 1360, components: [1200, 160])
    expect(e2).to eq([[470, 0, [415, 55]], [890, 1, [785, 105]]])

    # E3: a 1-cent refund, then a 1,359-cent loss: no excess, every share cleared.
    e3 = run([fact(kind: "refund", gross_cents: 1, refund_split: [1, 0]),
      fact(kind: "dispute_loss", gross_cents: 1359)], captured: 1360, components: [1200, 160])
    expect(e3).to eq([[1, 0, [1, 0]], [1359, 0, [1199, 160]]])
  end

  it "follows the frozen processing order: the 10-cent pair under both posting orders (L-17)" do
    refund = fact(kind: "refund", gross_cents: 6, refund_split: [6, 0])
    loss = fact(kind: "dispute_loss", gross_cents: 6)
    expect(run([refund, loss], captured: 10, components: [6, 4])).to eq([[6, 0, [6, 0]], [4, 2, [0, 4]]])
    # The loss first takes (4, 2); the refund's own items (6, 0) no longer fit.
    expect(run([loss, refund], captured: 10, components: [6, 4])).to eq([[6, 0, [4, 2]], [4, 2, [2, 2]]])
  end

  it "recomputes only the surviving facts after a reversal (late-win counterexample, L-18)" do
    refund = fact(kind: "refund", gross_cents: 4, refund_split: [4, 0])
    loss = fact(kind: "dispute_loss", gross_cents: 6)
    posted = described_class.recompute([refund, loss], captured_cents: 10, components: [6, 4], policy: "item_record")
    expect(posted.to_a).to eq([10, [6, 4]])
    survivors = described_class.recompute([refund], captured_cents: 10, components: [6, 4], policy: "item_record")
    expect(survivors.components.zip(posted.components).map { |goal, was| goal - was }).to eq([-2, -4])
    expect(survivors.components).to eq([4, 0])
  end

  it "splits the 75-cent example by policy while gross owed is identical (§5.5, E11, L-24)" do
    facts = [fact(kind: "refund", gross_cents: 1360, refund_split: [1200, 160]),
      fact(kind: "refund", gross_cents: 1200, refund_split: [1200, 0])]
    item_record = run(facts, captured: 2560, components: [2400, 160], policy: "item_record")
    pro_rata = run(facts, captured: 2560, components: [2400, 160], policy: "cumulative_pro_rata")
    expect(item_record.map(&:last)).to eq([[1200, 160], [1200, 0]])
    expect(pro_rata.map(&:last)).to eq([[1275, 85], [1125, 75]])
    expect(item_record.map { |applied, excess, _| [applied, excess] }).to eq(pro_rata.map { |applied, excess, _| [applied, excess] })
  end

  it "is exact, bounded, monotone and clears every share at full return for every split of C (L-02)" do
    [[1360, [1200, 160]], [2560, [2400, 160]]].each do |captured, components|
      %w[item_record cumulative_pro_rata].each do |policy|
        (0..captured).each do |first|
          facts = [fact(kind: "dispute_loss", gross_cents: first), fact(kind: "dispute_loss", gross_cents: captured - first)]
            .select { |fact| fact.gross_cents.positive? }
          steps = run(facts, captured: captured, components: components, policy: policy)
          totals = steps.map(&:last).transpose.map(&:sum)
          expect(totals).to eq(components), "#{policy} #{captured} split #{first}"
          expect(steps.flat_map(&:last)).to all(be >= 0)
          expect(steps.sum { |applied, _, _| applied }).to eq(captured)
        end
      end
    end
  end
end
