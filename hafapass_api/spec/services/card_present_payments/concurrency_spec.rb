require "rails_helper"
require "timeout"

RSpec.describe "Card-present lifecycle locking", :non_transactional do
  self.use_transactional_tests = false

  before do
    clean_test_data
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  after { clean_test_data }

  [:create, :success, :failure, :unknown, :replay].each do |operation|
    it "lets lifecycle order/payment locks finish before #{operation} takes payment or attempt locks" do
      event = create(:event, :published)
      user = event.organizer_profile.user
      account = create(:card_present_account, :verified, organization: event.organization)
      ticket_type = create(:ticket_type, event: event, price_cents: 1000)
      sale = Commerce::OrderCreator.call(event: event, user: user,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_email: "locking@example.invalid",
        buyer_name: "Locking fixture", payment_required: true, payment_provider: account.provider,
        source: "box_office", payment_method: "door_card", service_fee: false)
      attempt = unless operation == :create
        CardPresentPaymentAttempt.create!(organization: event.organization, event: event, order: sale.order,
          payment: sale.payment, card_present_account: account, initiated_by_user: user, provider: account.provider,
          idempotency_key: "locked-terminal", external_payment_id: "hp-locked", amount_cents: sale.payment.amount_cents,
          currency: "usd", initiated_at: Time.current)
      end
      result = CardPresentGateway::Result.new(provider_payment_id: "clover-locking", amount_cents: sale.payment.amount_cents,
        currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-locking" })
      gateway = instance_double(CardPresentGateway)
      if operation == :create
        expect(gateway).to receive(:charge).once do
          expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
          result
        end
      else
        expect(gateway).not_to receive(:charge)
      end

      order_locked = Queue.new
      release_lifecycle = Queue.new
      lifecycle_results = Queue.new
      worker_pid = Queue.new
      worker_results = Queue.new
      lifecycle = database_thread(lifecycle_results) do
        # Actual row-lock sequence used by OrderLifecycle.complete!/fail!.
        Order.transaction do
          Order.find(sale.order.id).lock!
          order_locked << true
          release_lifecycle.pop
          Payment.find(sale.payment.id).lock!
        end
        :lifecycle_finished
      end
      Timeout.timeout(5) { order_locked.pop }
      writer = database_thread(worker_results) do
        worker_pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
        processor = CardPresentPayments::Processor.new(order: Order.find(sale.order.id), payment: Payment.find(sale.payment.id),
          account: CardPresentAccount.find(account.id), user: User.find(user.id), idempotency_key: "locked-terminal", gateway: gateway)
        current_attempt = CardPresentPaymentAttempt.find(attempt.id) if attempt
        case operation
        when :create, :replay then processor.call
        when :success then processor.send(:record_success!, current_attempt, result)
        when :failure then processor.send(:record_failure!, current_attempt, CardPresentGateway::PaymentError.new("declined"))
        when :unknown then processor.send(:record_unknown!, current_attempt, CardPresentGateway::ResultUnknown.new("interrupted"))
        end
      end
      pid = Timeout.timeout(5) { worker_pid.pop }
      wait_for_database_lock(pid, worker_results)

      # An independent connection can still lock payment/attempt while the
      # writer waits for order. Otherwise lifecycle could complete a deadlock.
      Payment.transaction do
        Payment.find(sale.payment.id).lock!("FOR UPDATE NOWAIT")
        CardPresentPaymentAttempt.find(attempt.id).lock!("FOR UPDATE NOWAIT") if attempt
      end
      release_lifecycle << true
      Timeout.timeout(10) { lifecycle.join; writer.join }
      expect(lifecycle_results.pop).to eq(:lifecycle_finished)
      outcome = worker_results.pop
      if operation == :replay
        expect(outcome).to be_a(CardPresentPayments::Processor::ProcessingError)
        expect(outcome.message).to include("requires reconciliation")
      else
        expect(outcome).not_to be_a(Exception)
      end
      final_attempt = CardPresentPaymentAttempt.find_by!(payment: sale.payment)
      case operation
      when :create, :success
        expect(final_attempt).to be_status_succeeded
        expect(sale.order.reload).to be_completed
        expect(sale.order.tickets.count).to eq(1)
        expect(ticket_type.reload.quantity_sold).to eq(1)
      when :failure
        expect(final_attempt).to be_status_failed
        expect(sale.order.reload).to be_cancelled
        expect(sale.payment.reload).to be_failed
        expect(sale.order.inventory_holds).to all(be_released)
      when :unknown, :replay
        expect(final_attempt).to be_status_result_unknown
        expect(sale.order.reload).to be_pending
        expect(sale.order.inventory_holds).to all(be_active)
        expect(ReconciliationException.open).to exist(order: sale.order, code: "card_present_result_unknown")
      end
    ensure
      release_lifecycle << true if release_lifecycle
      [lifecycle, writer].compact.each do |thread|
        thread.join(2)
        thread.kill if thread.alive?
      end
    end
  end

  def database_thread(results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        results << yield
      rescue StandardError => error
        results << error
      ensure
        connection.execute("SET lock_timeout = 0")
      end
    end
  end

  def wait_for_database_lock(pid, results)
    Timeout.timeout(5) do
      loop do
        unless results.empty?
          outcome = results.pop
          raise outcome if outcome.is_a?(Exception)
          raise "Writer returned before entering lock contention"
        end
        break if ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?

        sleep 0.01
      end
    end
  end

  def clean_test_data
    raise "Isolated test database required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, site_settings RESTART IDENTITY CASCADE")
  end
end
