require "rails_helper"
require "timeout"

RSpec.describe "Commerce lock order", :non_transactional do
  self.use_transactional_tests = false

  before do
    clean_test_data
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(id: "pi_lock_#{order.id}", client_secret: "test_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
  end

  after { clean_test_data }

  def clean_test_data
    raise "Isolated test database required" unless Rails.env.test? &&
      ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE users, organizer_profiles, events, site_settings RESTART IDENTITY CASCADE")
  end

  def worker(role, results, &block)
    Thread.new do
      Thread.current[:lock_spec_role] = role
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.connection.execute("SET lock_timeout = '3s'")
        results << block.call
      ensure
        ApplicationRecord.connection.execute("RESET lock_timeout")
      end
    rescue StandardError => error
      results << error
    end
  end

  def wait(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def join(*threads)
    threads.each { |thread| expect(thread.join(5)).not_to be_nil }
  end

  def checkout(event, type, buyer:, key: nil)
    Commerce::OrderCreator.call(event: Event.find(event.id),
      line_items: [{ ticket_type_id: type.id, quantity: 1 }],
      buyer_email: "#{buyer}@example.invalid", buyer_name: buyer,
      checkout_key_digest: key, checkout_request_digest: key && "a" * 64)
  end

  it "finishes a cash sale racing a buyer checkout on the same event" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event, price_cents: 500, quantity_available: 10)
    cash_has_event = Queue.new
    continue_cash = Queue.new
    buyer_attempted_event = Queue.new
    cash_results = Queue.new
    buyer_results = Queue.new

    allow(Commerce::OrderCreator).to receive(:call).and_wrap_original do |method, **arguments|
      if Thread.current[:lock_spec_role] == :cash
        cash_has_event << true
        continue_cash.pop
      end
      method.call(**arguments)
    end
    allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |method, *arguments|
      buyer_attempted_event << true if Thread.current[:lock_spec_role] == :buyer
      method.call(*arguments)
    end

    cash = worker(:cash, cash_results) do
      Commerce::CashSaleCreator.call(event: Event.find(event.id), user: event.organizer_profile.user,
        parameters: { line_items: [{ ticket_type_id: type.id, quantity: 1 }], payment_method: "door_cash" },
        idempotency_key: "cash-lock-order")
    end
    wait(cash_has_event)
    buyer = worker(:buyer, buyer_results) { checkout(event, type, buyer: "buyer", key: "b" * 64) }
    wait(buyer_attempted_event)
    continue_cash << true
    join(cash, buyer)

    expect(wait(cash_results)).to be_a(Commerce::CashSaleCreator::Result)
    expect(wait(buyer_results)).to be_a(Commerce::OrderCreator::Result)
    expect(Order.where(event: event).count).to eq(2)
  ensure
    continue_cash << true if continue_cash&.empty?
    [cash, buyer].compact.each { |thread| thread.kill if thread.alive? }
  end

  it "finishes rejected setup racing completion without order-to-event inversion" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event, price_cents: 500, quantity_available: 10)
    created = checkout(event, type, buyer: "setup")
    order = created.order
    payment = created.payment
    payment.update!(provider_payment_id: nil, provider_payload: { "setup_lease_token" => "rejected-lease" })
    setup_has_order = Queue.new
    continue_setup = Queue.new
    completion_attempted_order = Queue.new
    setup_results = Queue.new
    completion_results = Queue.new

    allow_any_instance_of(Payment).to receive(:update!).and_wrap_original do |method, *arguments|
      attributes = arguments.first
      if Thread.current[:lock_spec_role] == :setup && attributes.is_a?(Hash) &&
          attributes[:provider_payload]&.exclude?("setup_lease_token")
        setup_has_order << true
        continue_setup.pop
      end
      method.call(*arguments)
    end
    allow_any_instance_of(Order).to receive(:lock!).and_wrap_original do |method, *arguments|
      completion_attempted_order << true if Thread.current[:lock_spec_role] == :completion
      method.call(*arguments)
    end

    creator = Commerce::OrderCreator.new(event: event, line_items: [], buyer_email: "setup@example.invalid", buyer_name: "setup")
    setup = worker(:setup, setup_results) do
      creator.send(:finish_failed_provider_setup!, Order.find(order.id), Payment.find(payment.id),
        "rejected-lease", StandardError.new("rejected"), rejected: true)
    end
    wait(setup_has_order)
    completion = worker(:completion, completion_results) do
      Commerce::OrderLifecycle.complete!(Order.find(order.id), payment: Payment.find(payment.id),
        provider_amount_cents: payment.amount_cents, provider_currency: payment.currency)
    end
    wait(completion_attempted_order)
    continue_setup << true
    join(setup, completion)

    expect(wait(setup_results)).not_to be_a(Exception)
    expect([:completed, :unchanged]).to include(wait(completion_results))
    expect(order.reload).not_to be_pending
    expect { creator.send(:finish_failed_provider_setup!, order, payment, "rejected-lease",
      StandardError.new("rejected"), rejected: true) }.not_to change { order.reload.status }
  ensure
    continue_setup << true if continue_setup&.empty?
    [setup, completion].compact.each { |thread| thread.kill if thread.alive? }
  end

  it "runs ordinary checkouts on different events of one organization without serializing" do
    first_event = create(:event, :published, starts_at: 5.days.from_now)
    second_event = create(:event, :published, organizer_profile: first_event.organizer_profile,
      starts_at: 5.days.from_now)
    first_type = create(:ticket_type, event: first_event, price_cents: 500)
    second_type = create(:ticket_type, event: second_event, price_cents: 500)
    first_has_event = Queue.new
    release_first = Queue.new
    second_attempted_event = Queue.new
    first_results = Queue.new
    second_results = Queue.new

    allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |method, *arguments|
      result = if Thread.current[:lock_spec_role] == :second
        second_attempted_event << true
        method.call(*arguments)
      else
        method.call(*arguments)
      end
      if Thread.current[:lock_spec_role] == :first && method.receiver.id == first_event.id
        first_has_event << true
        release_first.pop
      end
      result
    end

    first = worker(:first, first_results) { checkout(first_event, first_type, buyer: "first", key: "1" * 64) }
    wait(first_has_event)
    second = worker(:second, second_results) { checkout(second_event, second_type, buyer: "second", key: "2" * 64) }
    wait(second_attempted_event)
    expect(wait(second_results)).to be_a(Commerce::OrderCreator::Result)
    expect(first).to be_alive
    release_first << true
    join(first, second)
    expect(wait(first_results)).to be_a(Commerce::OrderCreator::Result)
  ensure
    release_first << true if release_first&.empty?
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end
end
