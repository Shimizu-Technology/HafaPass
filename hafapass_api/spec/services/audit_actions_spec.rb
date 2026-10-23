# frozen_string_literal: true

require "spec_helper"
require "ripper"
require_relative "../../app/services/audit_actions"

RSpec.describe AuditActions do
  # Parse Ruby instead of matching source lines. In emitter files, inventory
  # action-shaped literals in helper arguments/defaults, constants, assignments,
  # ternaries and lambda callbacks. Ignore SQL column arguments and other stores.
  class AuditActionSourceInventory
    ACTION = /\A[a-z][a-z_]*\.[a-z][a-z_]*(?:\.[a-z_]+)*\z/
    SQL_METHODS = %w[select pluck pick order reorder group joins].freeze
    attr_reader :keys, :dynamic

    def initialize(source)
      @keys, @dynamic = [], []
      tree = Ripper.sexp(source)
      raise "Cannot parse audit source" unless tree
      visit(tree)
    end

    def self.nodes(tree, type)
      return [] unless tree.is_a?(Array)
      return [tree] if tree.first == type
      tree.flat_map { |child| nodes(child, type) }
    end

    def self.normalized(tree)
      return tree unless tree.is_a?(Array)
      return tree.take(2) if tree.first.to_s.start_with?("@")
      return [:var_ref, normalized(tree[1])] if tree.first == :vcall
      tree.map { |child| normalized(child) }
    end

    def self.string_tree(source)
      normalized(nodes(Ripper.sexp(source), :string_literal).fetch(0))
    end

    def self.audit_emitter?(source)
      tree = Ripper.sexp(source)
      raise "Cannot parse application source" unless tree
      (nodes(tree, :call) + nodes(tree, :command_call)).any? do |call|
        call.dig(3, 1) == "record!" && nodes(call[1], :@const).any? { |token| token[1] == "AuditLogger" }
      end
    end

    def self.enum_keys(path, name)
      tree = Ripper.sexp(File.read(path))
      call = nodes(tree, :command).find do |node|
        node.dig(1, 1) == "enum" && nodes(node, :symbol_literal).first&.dig(1, 1, 1) == name
      end
      raise "Cannot find #{name} enum in #{path}" unless call
      nodes(nodes(call, :hash).fetch(0), :assoc_new).map do |association|
        key = association[1]
        raise "Unsupported enum key in #{path}" unless key[0] == :@label
        key[1].delete_suffix(":")
      end
    end

    private

    def call_name(node)
      case node&.first
      when :call then node.dig(3, 1)
      when :fcall, :vcall then node.dig(1, 1)
      end
    end

    def visit(node, audit_value = false)
      return unless node.is_a?(Array)
      if node[0] == :assoc_new && audit_value == :arguments
        visit(node[2], node.dig(1, 1) == "action:")
        return
      end
      if node[0] == :method_add_arg
        callable = node[1]
        if SQL_METHODS.include?(call_name(callable))
          visit(callable)
          return
        end
        constants = self.class.nodes(callable[1], :@const) if callable[0] == :call
        return if call_name(callable) == "record!" && constants&.any? && constants.none? { |token| token[1] == "AuditLogger" }
        if call_name(callable) == "record!" && constants&.any? { |token| token[1] == "AuditLogger" }
          visit(node[2], :arguments)
          return
        end
      end
      if node[0] == :string_literal
        content = node[1]
        fragments = self.class.nodes(content, :@tstring_content).map { |token| token[1] }
        if self.class.nodes(content, :string_embexpr).any?
          @dynamic << self.class.normalized(node) if audit_value == true || fragments.first&.match?(/\A[a-z][a-z_]*\./)
        elsif audit_value == true || fragments.join.match?(ACTION)
          @keys << fragments.join
        end
        return
      end
      node.each { |child| visit(child, audit_value) }
    end
  end

  let(:app_root) { File.expand_path("../../app", __dir__) }
  let(:inventory) do
    Dir[File.join(app_root, "**/*.rb")].sort.filter_map do |path|
      source = File.read(path)
      next unless AuditActionSourceInventory.audit_emitter?(source)
      [path.delete_prefix("#{app_root}/"), AuditActionSourceInventory.new(source)]
    end.to_h
  end

  it "registers every literal action, including forwarded helpers and constants" do
    missing = inventory.flat_map do |path, source|
      (source.keys.uniq - described_class.keys).map { |key| "#{path}: #{key}" }
    end
    expect(missing).to be_empty, "Unregistered audit actions:\n#{missing.join("\n")}"
    expect(inventory.size).to be >= 70
    expect(inventory.values.flat_map(&:keys)).to include("operations.synthetic_data_purged", "event_staff.assigned",
      "payment_readiness.approved", "connected_account.readiness_approved", "refund_reconciliation.retry", "sales.export_failed")
  end

  it "requires an explicit inventory for every interpolated action expression" do
    expected = {
      "services/live_pilot_runs/manager.rb" => [AuditActionSourceInventory.string_tree('"live_pilot_run.#{kind}"')],
      "services/payout_creator.rb" => [AuditActionSourceInventory.string_tree('"payout.#{attributes.fetch(:status)}"')]
    }
    actual = inventory.transform_values(&:dynamic).reject { |_path, expressions| expressions.empty? }
    expect(actual).to eq(expected), "Audit interpolation changed: enumerate its possible keys before recording it"
  end

  it "registers every pilot run kind and payout status, including enum additions" do
    { "live_pilot_run" => ["models/live_pilot_run_action.rb", "kind"], "payout" => ["models/payout.rb", "status"] }.each do |prefix, (path, enum)|
      keys = AuditActionSourceInventory.enum_keys(File.join(app_root, path), enum).map { |value| "#{prefix}.#{value}" }
      expect(keys - described_class.keys).to be_empty, "Unregistered #{prefix} enum actions: #{keys - described_class.keys}"
    end
  end

  it "parses single quotes, multiline calls, conditionals, helpers and constants without comments or SQL" do
    source = <<~'SOURCE'
      # AuditLogger.record!(action: "fake.comment")
      ACTION = 'operations.synthetic_data_purged'
      action = ok ? 'sample.success' : "sample.failure"
      audit!(action)
      audit!('sample.forwarded')
      AuditLogger.record!(
        action: action,
        metadata: { count: 2 }
      )
      records.pick("events.organization_id")
      Seating::Audit.record!(action: "seat.checked_in")
      AuditLogger.record!(action: "sample.#{kind}")
    SOURCE
    result = AuditActionSourceInventory.new(source)
    expect(result.keys).to contain_exactly("operations.synthetic_data_purged", "sample.success", "sample.failure", "sample.forwarded")
    expect(AuditActionSourceInventory.new('AuditLogger.record!(action: "unregistered")').keys).to eq(["unregistered"])
    expect(result.dynamic).to eq([AuditActionSourceInventory.string_tree('"sample.#{kind}"')])
    expect(AuditActionSourceInventory.audit_emitter?("AuditLogger.\n  record!(action: 'sample.new')")).to be(true)
    expect(AuditActionSourceInventory.audit_emitter?('# AuditLogger.record!(action: "fake.comment")')).to be(false)
  end

  it "fails closed for unknown keys without guessing scope from a prefix" do
    expect(described_class.registered?("event.new_action")).to be(false)
    expect(described_class.fetch("event.new_action")[:audience]).to eq(["admin_only"])
    expect(described_class.tenant?("event.new_action")).to be(false)
    expect(described_class.event_required?("event.new_action")).to be(false)
    expect(described_class.organization_payload("event.new_action", metadata: { event_id: 1 })).to eq(before_data: {}, after_data: {}, metadata: {})
  end

  it "gives every action valid explicit metadata and a plain English template" do
    described_class.keys.each do |key|
      definition = described_class.fetch(key)
      expect(described_class::AREAS).to include(definition.fetch(:area))
      expect(definition.fetch(:audience) - described_class::AUDIENCES).to be_empty
      expect([true, false]).to include(definition.fetch(:tenant), definition.fetch(:event_required))
      expect(definition.fetch(:template)).to match(/\A[A-Z].+\.\z/)
      expect(definition.fetch(:organization_fields).keys).to contain_exactly(:before_data, :after_data, :metadata)
      expect(definition[:tenant]).to be(true) if definition[:event_required]
      if definition[:audience] == ["admin_only"]
        expect(definition[:organization_fields].values).to all(be_empty)
      else
        expect(definition[:audience]).to include("org_owner")
      end
    end
  end

  it "separates audience from tenant and event scope" do
    expect(described_class.fetch("support.note_created")[:audience]).to eq(["admin_only"])
    expect(described_class.tenant?("support.note_created")).to be(true)
    expect(described_class.event_required?("support.note_created")).to be(false)
    %w[support.lookup platform.invitation_created user.role_updated annual_tax_report.exported tin_matching.exported platform_capability.approved privacy_request.executed legal_hold.placed].each do |key|
      expect(described_class.fetch(key)[:audience]).to eq(["admin_only"])
      expect(described_class.tenant?(key)).to be(false)
    end
    expect(described_class.tenant?("payment_readiness.approved")).to be(true)
    expect(described_class.event_required?("payment_readiness.approved")).to be(false)
    expect(described_class.event_required?("live_pilot_run.started")).to be(true)
    expect(described_class.event_required?("finance.exported")).to be(false)
  end

  it "gives managers operational history and finance staff financial history" do
    %w[event.page_customized event_staff.assigned ticket.checked_in scanner_device.revoked order.fulfillment_resent sales.export_downloaded].each do |key|
      expect(described_class.visible_to?(key, :org_manager)).to be(true)
      expect(described_class.visible_to?(key, :org_owner)).to be(true)
    end
    %w[payout.paid refund.created organizer_tax_information.updated balance_adjustment.posted finance.exported].each do |key|
      expect(described_class.visible_to?(key, :org_finance)).to be(true)
      expect(described_class.visible_to?(key, :org_manager)).to be(false)
    end
    %w[support.note_created event.policy_hold_placed live_pilot.approved platform_capability.approved].each do |key|
      expect(described_class.visible_to?(key, :org_owner)).to be(false)
    end
  end

  it "registers integration worker keys with the correct scope and queueing outcome" do
    %w[campaign.created campaign.updated campaign.deleted campaign.scheduled campaign.send_requested campaign.send_completed campaign.send_failed scanner_device.renamed scanner_device.manifest_downloaded].each do |key|
      expect(described_class.visible_to?(key, :org_manager)).to be(true)
      expect(described_class.tenant?(key)).to be(true)
      expect(described_class.event_required?(key)).to be(true)
    end
    expect(described_class.fetch("campaign.send_completed")[:template]).to eq("Queued a campaign for delivery.")
    expect(described_class.fetch("platform.activity_logging_started")[:audience]).to eq(["admin_only"])
    expect(described_class.tenant?("platform.activity_logging_started")).to be(false)
  end

  it "projects only allowed scalar fields, retaining false, zero and nil" do
    payload = described_class.organization_payload("payout.reconciled",
      before_data: { status: "pending", request_id: "private", buyer_email: "private@example.test" },
      after_data: { "status" => "paid", "paid_at" => nil, "under_withheld_cents" => 0, "provider_payout_id" => "private" },
      metadata: { amount_cents: 100, reason: "internal note", provider_result: { email: "private" }, ip_address: "127.0.0.1" })
    expect(payload).to eq(before_data: { "status" => "pending" },
      after_data: { "status" => "paid", "paid_at" => nil, "under_withheld_cents" => 0 }, metadata: { "amount_cents" => 100 })
    expect(described_class.organization_payload("connected_account.onboarding_started",
      after_data: { charges_enabled: false, status: { internal_notes: "private" }, payout_details: { email: "private" } })[:after_data]).to eq("charges_enabled" => false)
  end

  it "excludes buyer contacts, network identifiers, internal notes and review evidence from all allowlists" do
    prohibited = /email|phone|address|\Arequest_id\z|ip_address|note|reason\z|evidence|digest|token|credential|buyer|attendee_name|provider_result|filter|columns|payout_details|capabilities|controls/
    described_class.keys.each do |key|
      fields = described_class.fetch(key)[:organization_fields].values.flatten
      expect(fields.grep(prohibited)).to be_empty, "Unsafe organization fields for #{key}: #{fields.grep(prohibited)}"
    end
    expect(described_class.organization_payload("support.note_created", after_data: { body: "private" })[:after_data]).to eq({})
  end

  it "documents every registered key in the coverage table" do
    document = File.read(File.expand_path("../../../docs/AUDIT_ACTION_REGISTRY.md", __dir__))
    missing = described_class.keys.reject { |key| document.include?("| `#{key}` |") }
    expect(missing).to be_empty, "Add coverage table rows for: #{missing.join(', ')}"
  end

  it "keeps definitions immutable and accepts symbol action keys" do
    expect(described_class.fetch(:"payout.paid")).to equal(described_class.fetch("payout.paid"))
    expect { described_class.fetch("payout.paid")[:audience] << "org_manager" }.to raise_error(FrozenError)
    expect { described_class.fetch("payout.paid")[:organization_fields][:metadata] << "buyer_email" }.to raise_error(FrozenError)
  end
end
