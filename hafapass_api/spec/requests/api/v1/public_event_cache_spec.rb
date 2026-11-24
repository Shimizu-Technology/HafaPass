# frozen_string_literal: true

require "rails_helper"

# The public event cache stays on during a rush, so a sell-out (and inventory
# coming back) must reach every Puma worker before the 15-second TTL ends.
RSpec.describe "Public event cache inventory freshness", type: :request do
  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes) }
  let!(:organizer_profile) { create(:organizer_profile) }
  let!(:event) do
    create(:event, :published, organizer_profile: organizer_profile, organization: organizer_profile.organization,
      title: "Copa Final", starts_at: 6.days.from_now, max_capacity: nil)
  end
  let!(:ticket_type) { create(:ticket_type, :free, event: event, quantity_available: 2, max_per_order: 1) }

  before do
    SiteSetting.instance
    allow(Rails).to receive(:cache).and_return(memory_cache)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
  end

  def show_ticket_type
    get "/api/v1/events/#{event.slug}"
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("ticket_types").find { |row| row["id"] == ticket_type.id }
  end

  def listed_event(**params)
    get "/api/v1/events", params: params
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("events").find { |row| row["id"] == event.id }
  end

  def buy!(index)
    Commerce::OrderCreator.call(event: Event.find(event.id), line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "cache-#{index}@example.invalid", buyer_name: "Cache Buyer #{index}", enforce_buyer_limits: true,
      checkout_ip_digest: Digest::SHA256.hexdigest("cache-#{index}"))
  end

  it "keeps serving the cached page for ordinary sales and shows sold out as soon as the last ticket goes" do
    expect(show_ticket_type).to include("quantity_remaining" => 2, "sold_out" => false)
    expect(listed_event.fetch("sold_out")).to be(false)

    expect { buy!(1) }.not_to(change { PublicEventCache.generation })
    # Within the TTL a non-exhausting sale may still show the earlier count.
    expect(show_ticket_type).to include("quantity_remaining" => 2)

    expect { buy!(2) }.to change { PublicEventCache.generation }.by(1)
    expect(show_ticket_type).to include("quantity_remaining" => 0, "sold_out" => true)
    # The default listing hides sold-out events; the hub view keeps them, marked.
    expect(listed_event).to be_nil
    hub = listed_event(organizer: organizer_profile.organization.slug, include_sold_out: "true")
    expect(hub.fetch("sold_out")).to be(true)
  end

  it "shows returned inventory promptly when a held order is cancelled" do
    paid = create(:ticket_type, event: event, name: "Paid GA", price_cents: 2500, quantity_available: 1, max_per_order: 1)
    allow(StripeService).to receive(:create_payment_intent) do |order, idempotency_key:, **|
      OpenStruct.new(id: "pi_cache_#{order.id}", client_secret: "#{idempotency_key}_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    held = Commerce::OrderCreator.call(event: Event.find(event.id), line_items: [{ ticket_type_id: paid.id, quantity: 1 }],
      buyer_email: "held@example.invalid", buyer_name: "Held Buyer", payment_required: true)
    expect(held.order).to be_pending
    get "/api/v1/events/#{event.slug}"
    expect(response.parsed_body.fetch("ticket_types").find { |row| row["id"] == paid.id }).to include("sold_out" => true)

    expect { Commerce::OrderLifecycle.cancel!(held.order) }.to change { PublicEventCache.generation }.by(1)

    get "/api/v1/events/#{event.slug}"
    expect(response.parsed_body.fetch("ticket_types").find { |row| row["id"] == paid.id })
      .to include("quantity_remaining" => 1, "sold_out" => false)
  end

  it "shows an organizer capacity change without waiting for the TTL" do
    2.times { |index| buy!(index) }
    expect(show_ticket_type).to include("sold_out" => true)

    expect { ticket_type.update!(quantity_available: 5) }.to change { PublicEventCache.generation }.by(1)
    expect(show_ticket_type).to include("quantity_remaining" => 3, "sold_out" => false)
  end

  it "shows a cancelled ticket's returned inventory" do
    sold = 2.times.map { |index| buy!(index) }
    expect(show_ticket_type).to include("sold_out" => true)

    ticket = sold.first.order.tickets.first
    expect do
      Ticket.transaction do
        ticket.lock!
        ticket.cancel_unused_and_release_inventory!(reason: "spec")
      end
    end.to change { PublicEventCache.generation }.by(1)
    expect(show_ticket_type).to include("quantity_remaining" => 1, "sold_out" => false)
  end

  it "does not move the generation for checkout refusals or a rolled-back sale" do
    2.times { |index| buy!(index) }
    expect { expect { buy!(3) }.to raise_error(Commerce::OrderCreator::CheckoutError) }
      .not_to(change { PublicEventCache.generation })

    ticket_type.update!(quantity_available: 3)
    expect do
      ApplicationRecord.transaction do
        buy!(4)
        raise ActiveRecord::Rollback
      end
    end.not_to(change { PublicEventCache.generation })
    expect(ticket_type.reload.available_quantity).to eq(1)
  end

  def bump_statements
    statements = []
    callback = ->(*, payload) { statements << payload[:name] if payload[:name] == "PublicEventCache Bump" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements.size
  end

  it "turns the cache off, and its generation writes, with HAFAPASS_PUBLIC_EVENT_CACHE=off" do
    show_ticket_type
    original = ENV["HAFAPASS_PUBLIC_EVENT_CACHE"]
    ENV["HAFAPASS_PUBLIC_EVENT_CACHE"] = "off"
    event.update_column(:title, "Copa Final Updated")

    get "/api/v1/events/#{event.slug}"
    expect(response.parsed_body.fetch("title")).to eq("Copa Final Updated")

    writes = bump_statements do
      expect do
        ticket_type.update!(quantity_available: 3)
        3.times { |index| buy!(index) }
        PublicEventCache.bump_after_commit!
      end.not_to(change { PublicEventCache.generation })
    end
    expect(writes).to eq(0)
  ensure
    original.nil? ? ENV.delete("HAFAPASS_PUBLIC_EVENT_CACHE") : ENV["HAFAPASS_PUBLIC_EVENT_CACHE"] = original
  end

  it "bumps once for a transaction that returns many tickets" do
    ticket_type.update!(quantity_available: 5)
    tickets = 5.times.map { |index| buy!(index).order.tickets.first }
    expect(show_ticket_type).to include("sold_out" => true)

    writes = bump_statements do
      expect do
        Ticket.transaction do
          tickets.each do |ticket|
            ticket.lock!
            ticket.cancel_unused_and_release_inventory!(reason: "spec")
          end
        end
      end.to change { PublicEventCache.generation }.by(1)
    end
    expect(writes).to eq(1)
    expect(show_ticket_type).to include("quantity_remaining" => 5, "sold_out" => false)
  end

  it "keeps bumping after a rolled-back transaction or savepoint" do
    expect do
      ApplicationRecord.transaction do
        ticket_type.update!(quantity_available: 4)
        raise ActiveRecord::Rollback
      end
    end.not_to(change { PublicEventCache.generation })
    expect { ticket_type.update!(quantity_available: 5) }.to change { PublicEventCache.generation }.by(1)

    other = create(:ticket_type, :free, event: event, name: "Other", quantity_available: 2)
    writes = bump_statements do
      expect do
        ApplicationRecord.transaction do
          ApplicationRecord.transaction(requires_new: true) do
            ticket_type.update!(quantity_available: 6)
            raise ActiveRecord::Rollback
          end
          other.update!(quantity_available: 3)
          ticket_type.reload.update!(quantity_available: 7)
        end
      end.to change { PublicEventCache.generation }.by(1)
    end
    expect(writes).to eq(1)
  end
end
