require "rails_helper"
require "timeout"

RSpec.describe "Organizer inventory edit concurrency", type: :request, non_transactional: true do
  self.use_transactional_tests = false

  before do
    raise "Concurrency fixtures require test" unless Rails.env.test?

    clean_test_data
    @user = create(:user, :organizer)
    profile = create(:organizer_profile, user: @user)
    @event = create(:event, :published, organizer_profile: profile, starts_at: 5.days.from_now, max_capacity: 2)
    @type = create(:ticket_type, event: @event, quantity_available: 2)
    @headers = auth_headers(@user)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(id: "pi_edit_#{order.id}", client_secret: "fixture_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  after { clean_test_data }

  it "serializes a ticket-type reduction with a buyer reserving the same inventory" do
    race_checkout_with_edit(TicketType, :sold_quantity_within_capacity,
      "/api/v1/organizer/events/#{@event.id}/ticket_types/#{@type.id}", quantity_available: 1)
  end

  it "serializes an event-capacity reduction with a buyer reserving tickets" do
    race_checkout_with_edit(Event, :capacity_covers_committed_inventory,
      "/api/v1/organizer/events/#{@event.id}", max_capacity: 1)
  end

  it "keeps held inventory visible while a payment finalizes during an event-capacity edit" do
    sale = checkout
    validation_started = Queue.new
    release_validation = Queue.new
    pause_validation(Event, :capacity_covers_committed_inventory, validation_started, release_validation)
    editor_results = Queue.new
    editor = worker(editor_results) { update_event(max_capacity: 1) }
    Timeout.timeout(10) { validation_started.pop }

    finalizer_results = Queue.new
    finalizer_pid = Queue.new
    finalizer = worker(finalizer_results, pid: finalizer_pid) do
      Commerce::OrderLifecycle.complete!(Order.find(sale.order.id), payment: Payment.find(sale.payment.id))
    end
    expect(wait_for_block_or_result(finalizer_pid.pop, finalizer_results)).to eq(:blocked)
    release_validation << true
    join_workers(editor, finalizer)

    expect(editor_results.pop).to eq(422)
    expect(finalizer_results.pop).to eq(:completed)
    expect(@event.reload.max_capacity).to eq(2)
    expect(@type.reload.quantity_sold).to eq(2)
    expect(@event.inventory_holds.current.sum(:quantity)).to eq(0)
    expect(Ticket.where(order: sale.order).count).to eq(2)
  ensure
    release_validation << true if release_validation&.empty?
    stop_workers(editor, finalizer)
  end

  it "rejects a reduction below an already committed buyer hold without losing the reservation" do
    sale = checkout
    expect(update_event(max_capacity: 1)).to eq(422)
    request = ActionDispatch::Integration::Session.new(Rails.application)
    request.put("/api/v1/organizer/events/#{@event.id}/ticket_types/#{@type.id}",
      params: { quantity_available: 1 }, headers: @headers)
    expect(request.response.status).to eq(422)
    expect(@type.reload.quantity_available).to eq(2)
    expect(@event.reload.max_capacity).to eq(2)
    expect(sale.order.inventory_holds.current.sum(:quantity)).to eq(2)
  end

  private

  def race_checkout_with_edit(model, validation, path, attributes)
    validation_started = Queue.new
    release_validation = Queue.new
    pause_validation(model, validation, validation_started, release_validation)
    editor_results = Queue.new
    editor = worker(editor_results) do
      request = ActionDispatch::Integration::Session.new(Rails.application)
      request.put(path, params: attributes, headers: @headers)
      request.response.status
    end
    Timeout.timeout(10) { validation_started.pop }
    buyer_results = Queue.new
    buyer_pid = Queue.new
    buyer = worker(buyer_results, pid: buyer_pid) { checkout }
    # Wait for a real database lock wait or a completed checkout, rather than
    # using timing to assume the competing buyer has reached the critical gap.
    expect(wait_for_block_or_result(buyer_pid.pop, buyer_results)).to eq(:blocked)
    release_validation << true
    join_workers(editor, buyer)
    expect(editor_results.pop).to eq(200)
    expect(buyer_results.pop).to be_a(Commerce::OrderCreator::CheckoutError)
    expect(@event.inventory_holds.current.sum(:quantity)).to eq(0)
    expect(@type.reload.quantity_sold).to eq(0)
  ensure
    release_validation << true if release_validation&.empty?
    stop_workers(editor, buyer)
  end

  def pause_validation(model, validation, started, release)
    allow_any_instance_of(model).to receive(validation).and_wrap_original do |original, *args|
      original.call(*args)
      started << true
      Timeout.timeout(10) { release.pop }
    end
  end

  def checkout
    Commerce::OrderCreator.call(event: Event.find(@event.id),
      line_items: [{ ticket_type_id: @type.id, quantity: 2 }],
      buyer_email: "inventory-edit@example.invalid", buyer_name: "Inventory buyer")
  end

  def update_event(attributes)
    request = ActionDispatch::Integration::Session.new(Rails.application)
    request.put("/api/v1/organizer/events/#{@event.id}", params: attributes, headers: @headers)
    request.response.status
  end

  def worker(results, pid: nil)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value("SELECT pg_backend_pid()") if pid
        results << yield
      rescue StandardError => error
        results << error
      end
    end
  end

  def wait_for_block_or_result(pid, results)
    Timeout.timeout(10) do
      loop do
        return :completed unless results.empty?
        return :blocked if ActiveRecord::Base.connection.select_value(
          "SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0"
        )

        sleep 0.01
      end
    end
  end

  def join_workers(*threads)
    Timeout.timeout(10) { threads.each(&:join) }
  end

  def stop_workers(*threads)
    threads.compact.each { |thread| thread.kill if thread.alive? }
    threads.compact.each(&:join)
  end

  def clean_test_data
    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end
end
