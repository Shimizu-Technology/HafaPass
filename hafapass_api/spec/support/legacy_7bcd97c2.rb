# frozen_string_literal: true

# The 7bcd97c2 refund and payout writers, the release A1-R1 overlaps with
# during a Render zero-downtime deploy (design §10.3). Its RefundCreator,
# LateCaptureRefund, PayoutCreator, PayoutReconciler, OrganizationPayoutBalance,
# Settlements::Calculator and Settlements::Finalizer are loaded verbatim under
# Legacy7bcd97c2 (so the old writers use the old readers); every other
# constant resolves to the current application, which matches 7bcd97c2 for
# what those two classes call. Loaded on first use only.
module Legacy7bcd97c2
  module Commerce
    def self.const_missing(name)
      ::Commerce.const_get(name)
    end
  end

  module Settlements
    def self.const_missing(name)
      ::Settlements.const_get(name)
    end
  end

  FILES = %w[late_capture_refund refund_creator settlements_calculator organization_payout_balance payout_creator
    payout_reconciler settlements_finalizer].freeze

  def self.load!
    return if @loaded

    dir = File.expand_path("legacy_7bcd97c2", __dir__)
    FILES.each do |name|
      path = File.join(dir, "#{name}.rb.txt")
      module_eval(File.read(path), path, 1)
    end
    [Commerce::RefundCreator, Commerce::LateCaptureRefund].each do |klass|
      klass.define_singleton_method(:const_missing) { |name| ::Commerce.const_get(name) }
    end
    [Settlements::Calculator, Settlements::Finalizer].each do |klass|
      klass.define_singleton_method(:const_missing) { |name| ::Settlements.const_get(name) }
    end
    @loaded = true
  end

  def self.payout_creator
    load!
    PayoutCreator
  end

  def self.payout_reconciler
    load!
    PayoutReconciler
  end

  def self.settlements_calculator
    load!
    Settlements::Calculator
  end

  def self.settlements_finalizer
    load!
    Settlements::Finalizer
  end

  def self.refund_creator
    load!
    Commerce::RefundCreator
  end

  def self.late_capture_refund
    load!
    Commerce::LateCaptureRefund
  end
end
