require "rails_helper"

RSpec.describe "Event operational auditing", type: :model do
  let(:operator) { create(:user, :organizer) }
  let(:event) { create(:event, organizer_profile: create(:organizer_profile, :verified, user: operator)) }
  let(:ticket_type) { create(:ticket_type, event: event) }

  before do
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_waitlist_offer_async)
  end

  after { AuditContext.reset }

  def logs(action, record)
    AuditLog.where(action: action, auditable_type: record.class.name, auditable_id: record.id)
  end

  def as_operator(&block)
    AuditContext.set(actor: operator, source: "user", request_id: "operations-request", &block)
  end

  configurations = [
    [:ticket_type, "ticket_type", { price_cents: 2300, quantity_available: 80, max_per_order: 4,
      max_per_buyer: 6, door_allocation: 10 }, { name: "Private title", description: "Private description" }],
    [:pricing_tier, "pricing_tier", { price_cents: 1200, quantity_limit: 25, position: 3 }, { name: "Private tier" }],
    [:promo_code, "promo_code", { discount_value: 15, max_uses: 8, active: false }, { code: "PRIVATECODE" }],
    [:guest_list_entry, "guest_list", { quantity: 3 }, { guest_name: "Private guest", guest_email: "private@example.test",
      guest_phone: "5551212", notes: "Private notes" }],
    [:venue_layout, "venue_layout", { version: 2, status: "retired" }, { name: "Private layout" }],
    [:promoter, "promoter", { commission_bps: 250, active: false }, { name: "Private promoter", email: "private@example.test" }],
    [:distribution_link, "distribution_link", { active: false }, { campaign: "private-campaign" }],
    [:catalog_item, "catalog_item", { price_cents: 2200, inventory_quantity: 30, active: false },
      { name: "Private item", description: "Private description" }],
    [:registration_question, "registration_question", { required: false, position: 4 }, { prompt: "Private prompt" }],
    [:event_waiver, "event_waiver", { active: false, required: false }, { title: "Private title", body: "Private waiver body" }]
  ]

  configurations.each do |factory, prefix, update, private_update|
    context prefix do
      let(:record) do
        case factory
        when :pricing_tier then create(factory, :quantity_based, ticket_type: ticket_type)
        when :guest_list_entry
          GuestListEntry.create!(event: event, ticket_type: ticket_type, guest_name: "Original guest", quantity: 1)
        when :venue_layout then create(factory, organization: event.organization)
        else create(factory, event: event)
        end
      end

      it "audits create/update/delete once with changed selected fields and the actual operator" do
        as_operator do
          item = record
          expect(logs("#{prefix}.created", item).count).to eq(1)
          item.update!(update)
          entry = logs("#{prefix}.updated", item).sole
          expect(entry.actor_user).to eq(operator)
          expect(entry.after_data).to eq(update.stringify_keys)
          expect(entry.before_data.keys).to match_array(update.keys.map(&:to_s))
          item.update!(update)
          expect(logs("#{prefix}.updated", item).count).to eq(1)
          item.destroy!
          expect(logs("#{prefix}.deleted", item).count).to eq(1)
        end
      end

      it "records text/contact changes by field name without copying their values" do
        as_operator do
          item = record
          item.update!(private_update)
          entry = logs("#{prefix}.updated", item).sole
          private_update.each_key do |field|
            expect(entry.metadata.fetch("changed_fields")).to include(field.to_s)
            expect(entry.before_data).not_to have_key(field.to_s)
            expect(entry.after_data).not_to have_key(field.to_s)
          end
          private_update.each_value { |value| expect(entry.attributes.to_json).not_to include(value) }
        end
      end
    end
  end

  it "captures ticket and pricing-tier limits and sale windows without unrelated attributes" do
    tier = create(:pricing_tier, :time_based, ticket_type: ticket_type)
    start = 1.day.from_now.change(usec: 0)
    finish = 2.days.from_now.change(usec: 0)
    as_operator do
      ticket_type.update!(sales_start_at: start, sales_end_at: finish)
      tier.update!(starts_at: start, ends_at: finish)
    end
    expect(logs("ticket_type.updated", ticket_type).sole.after_data.keys).to match_array(%w[sales_start_at sales_end_at])
    expect(logs("pricing_tier.updated", tier).sole.after_data.keys).to match_array(%w[starts_at ends_at])
  end

  it "rolls back a mutation and its already-inserted audit row if auditing fails" do
    item = create(:catalog_item, event: event)
    previous_price = item.price_cents
    allow(AuditLogger).to receive(:record!).and_wrap_original do |method, **arguments|
      result = method.call(**arguments)
      raise "audit storage interrupted" if arguments[:action] == "catalog_item.updated"
      result
    end
    expect do
      CatalogItem.transaction(requires_new: true) { as_operator { item.update!(price_cents: 7000) } }
    end.to raise_error("audit storage interrupted")
    expect(item.reload.price_cents).to eq(previous_price)
    expect(logs("catalog_item.updated", item)).to be_empty
  end

  it "rolls back creation and deletion when the audit write fails" do
    item = create(:promoter, event: event)
    allow(AuditLogger).to receive(:record!).and_raise("audit unavailable")
    expect { Promoter.transaction(requires_new: true) { item.destroy! } }.to raise_error("audit unavailable")
    expect(Promoter.exists?(item.id)).to be(true)
    expect do
      Promoter.transaction(requires_new: true) { create(:promoter, event: event) }
    end.to raise_error("audit unavailable")
    expect(event.promoters.count).to eq(1)
  end

  it "uses a system source for actorless writes, including jobs and public waitlist joins" do
    entry = create(:waitlist_entry, event: event)
    expect(AuditLogger).to have_received(:record!).with(hash_including(
      action: "waitlist.joined", auditable: entry, actor: nil, source: "system", outcome: "succeeded", event: event
    ))
  end

  it "audits guest redemption as the operator, excluding the buyer and added_by contacts" do
    entry = GuestListEntry.create!(event: event, ticket_type: ticket_type, guest_name: "Guest",
      added_by: "another-operator@example.test", quantity: 1)
    order = create(:order, event: event)
    as_operator { entry.redeem!(order) }
    audit = logs("guest_list.redeemed", entry).sole
    expect(audit.actor_user).to eq(operator)
    expect(audit.after_data).to eq("redeemed" => true, "order_id" => order.id)
    expect(audit.attributes.to_json).not_to include(order.buyer_email, entry.added_by)
    expect(logs("guest_list.updated", entry)).to be_empty
  end

  it "tracks waitlist notification requests, offers, claims, conversion, expiration and cancellation" do
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    offer = nil
    as_operator do
      entry.notify!
      offer = create(:waitlist_offer, waitlist_entry: entry)
      entry.update!(status: :offered, expires_at: offer.expires_at)
    end
    offer.update!(status: :claimed, claimed_at: Time.current)
    offer.update!(status: :converted, converted_at: Time.current)
    entry.update!(status: :converted)
    expect(AuditLogger).to have_received(:record!).with(hash_including(action: "waitlist.notification_requested",
      actor: operator, outcome: "requested"))
    expect(logs("waitlist.offered", entry).sole.actor_user).to eq(operator)
    %w[created claimed converted].each { |suffix| expect(logs("waitlist_offer.#{suffix}", offer).count).to eq(1) }
    expect(logs("waitlist.converted", entry).count).to eq(1)

    other_entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    other_offer = create(:waitlist_offer, waitlist_entry: other_entry)
    other_entry.update!(status: :offered)
    expect(other_offer.expire!).to be(true)
    expect(other_offer.expire!).to be(false)
    expect(logs("waitlist_offer.expired", other_offer).count).to eq(1)
    expect(logs("waitlist.requeued", other_entry).count).to eq(1)
    as_operator { other_entry.update!(status: :cancelled) }
    expect(logs("waitlist.cancelled", other_entry).sole.actor_user).to eq(operator)
    other_entry.update!(status: :waiting)
    expect(logs("waitlist.rejoined", other_entry).count).to eq(1)
    other_entry.update!(status: :expired)
    expect(logs("waitlist.expired", other_entry).count).to eq(1)
  end

  it "promotes all lifecycle history actions once, using the history actor and a stable identity" do
    other_actor = create(:user)
    { publish: "published", postpone: "postponed", resume: "resumed", cancel: "cancelled",
      complete: "completed", archive: "archived" }.each do |action, suffix|
      change = nil
      AuditContext.set(actor: other_actor, source: "admin") do
        change = event.event_state_changes.create!(actor_user: operator, action: action, from_status: "draft",
          to_status: suffix, reason: "Private lifecycle reason", occurred_at: Time.current)
      end
      audit = logs("event.#{suffix}", event).sole
      expect(audit.actor_user).to eq(operator)
      expect(audit.before_data).to eq("status" => "draft")
      expect(audit.after_data).to eq("status" => suffix)
      expect(audit.attributes.to_json).not_to include("Private lifecycle reason")
      expect(AuditLogger).to have_received(:record!).with(hash_including(action: "event.#{suffix}",
        deduplication_key: "event_state_change/#{change.id}", event: event))
    end
  end

  it "rolls back event status and state history when lifecycle promotion fails" do
    ticket_type.update!(price_cents: 0)
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "event.published")).and_raise("audit unavailable")
    expect do
      Event.transaction(requires_new: true) { EventLifecycle.call(event: event, action: :publish, actor: operator) }
    end.to raise_error("audit unavailable")
    expect(event.reload).to be_draft
    expect(event.event_state_changes).to be_empty
    expect(logs("event.published", event)).to be_empty
  end

  it "audits event creation, edits, copies, recurrences and deletion without repeating lifecycle or design audits" do
    original = event
    as_operator do
      original.update!(title: "Private event title", max_capacity: 120)
      audit = logs("event.updated", original).sole
      expect(audit.after_data).to eq("max_capacity" => 120)
      expect(audit.metadata.fetch("changed_fields")).to contain_exactly("title", "slug", "max_capacity")
      copy = build(:event, organizer_profile: original.organizer_profile, organization: original.organization)
      copy.audit_clone_source = original
      copy.save!
      expect(logs("event.cloned", copy).sole.metadata.fetch("source_event_id")).to eq(original.id)
      expect(logs("event.created", copy)).to be_empty
      recurrence = create(:event, organizer_profile: original.organizer_profile, recurrence_parent_id: original.id)
      expect(logs("event.recurrence_created", recurrence).count).to eq(1)
      original.update!(status: :published, page_customization: { accent: "#112233" })
      expect(logs("event.updated", original).count).to eq(1)
      copy.destroy!
      expect(logs("event.deleted", copy).count).to eq(1)
    end
  end

  it "attributes fulfillment to the actual fulfiller and preserves idempotent fulfillment" do
    order = create(:order, event: event)
    item = order.order_items.create!(item_kind: :add_on, catalog_item: create(:catalog_item, event: event),
      name: "Add on", quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000, organizer_proceeds_cents: 1000)
    fulfillment = CatalogFulfillment.create!(order_item: item)
    expect(fulfillment.fulfill!(user: operator)).to be(true)
    expect(fulfillment.fulfill!(user: create(:user))).to be(false)
    expect(logs("catalog_fulfillment.fulfilled", fulfillment).sole.actor_user).to eq(operator)
    expect(AuditLogger).to have_received(:record!).with(hash_including(
      action: "catalog_fulfillment.fulfilled", actor: operator, event: event
    ))
  end

  it "audits cancellation and each credential rotation once without storing credentials" do
    ticket = create(:ticket, event: event, ticket_type: ticket_type, order: create(:order, event: event))
    as_operator do
      ticket.rotate_scan_credential!
      ticket.revoke_display_credential!
      ticket.update!(status: :cancelled, cancellation_reason: "Private cancellation reason", cancelled_at: Time.current,
        scan_credential_version: ticket.scan_credential_version + 1)
    end
    %w[scan_credential_rotated display_credential_revoked cancelled].each do |suffix|
      audit = logs("ticket.#{suffix}", ticket).sole
      expect(audit.actor_user).to eq(operator)
      expect(audit.attributes.to_json).not_to include("Private cancellation reason")
      expect(audit.before_data).not_to have_key("qr_code")
      expect(audit.after_data).not_to have_key("qr_code")
    end
  end

  it "rolls back an atomic credential counter update when its audit fails" do
    ticket = create(:ticket, event: event, ticket_type: ticket_type, order: create(:order, event: event))
    previous_version = ticket.scan_credential_version
    allow(AuditLogger).to receive(:record!).and_raise("audit unavailable")
    expect do
      Ticket.transaction(requires_new: true) { ticket.rotate_scan_credential! }
    end.to raise_error("audit unavailable")
    expect(ticket.reload.scan_credential_version).to eq(previous_version)
  end

  it "attributes transfer initiation and acceptance to their actual users, and cancellation to the current operator" do
    ticket = create(:ticket, event: event, ticket_type: ticket_type, order: create(:order, event: event))
    recipient = create(:user)
    transfer = create(:ticket_transfer, ticket: ticket, initiated_by_user: operator, recipient_email: recipient.email)
    transfer.update!(status: :accepted, accepted_by_user: recipient, accepted_at: Time.current)
    expect(logs("ticket_transfer.created", transfer).sole.actor_user).to eq(operator)
    expect(logs("ticket_transfer.accepted", transfer).sole.actor_user).to eq(recipient)
    expect(AuditLogger).to have_received(:record!).with(hash_including(action: "ticket_transfer.accepted", event: event))
    as_operator do
      second = create(:ticket_transfer, ticket: ticket, initiated_by_user: recipient)
      second.update!(status: :cancelled)
      expect(logs("ticket_transfer.cancelled", second).sole.actor_user).to eq(operator)
      expect(logs("ticket_transfer.cancelled", second).sole.attributes.to_json).not_to include(second.recipient_email)
    end
  end
  it "rolls back an issued offer and entry transition when offer auditing fails" do
    event.update!(status: :published)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    ticket_type.update!(price_cents: 0)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "waitlist.offered")).and_raise("audit unavailable")
    expect do
      Event.transaction(requires_new: true) { as_operator { WaitlistOffers::Issuer.call(entry: entry) } }
    end.to raise_error("audit unavailable")
    expect(entry.reload).to be_waiting
    expect(entry.waitlist_offers).to be_empty
    expect(AuditLog.where(action: "waitlist_offer.created", organization_id: event.organization_id)).to be_empty
    expect(EmailService).not_to have_received(:send_waitlist_offer_async)
  end

  it "rolls back transfer acceptance, holder and both credentials when acceptance auditing fails" do
    event.update!(status: :published)
    ticket = create(:ticket, event: event, ticket_type: ticket_type, order: create(:order, event: event))
    recipient = create(:user)
    original_holder = ticket.holder_user_id
    original_scan_version = ticket.scan_credential_version
    original_display_version = ticket.display_credential_version
    allow(ClerkIdentity).to receive(:email_matches?).with(user: recipient, email: recipient.email).and_return(true)
    transfer = create(:ticket_transfer, ticket: ticket, recipient_email: recipient.email)
    token = TicketTransferCredential.issue(transfer)
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "ticket_transfer.accepted"))
      .and_raise("audit unavailable")
    expect do
      TicketTransfer.transaction(requires_new: true) { TicketTransfers::Manager.accept!(token: token, user: recipient) }
    end.to raise_error("audit unavailable")
    expect(transfer.reload).to be_pending
    expect(ticket.reload.holder_user_id).to eq(original_holder)
    expect(ticket.scan_credential_version).to eq(original_scan_version)
    expect(ticket.display_credential_version).to eq(original_display_version)
    expect(logs("ticket.scan_credential_rotated", ticket)).to be_empty
  end
end
