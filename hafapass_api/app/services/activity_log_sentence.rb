# frozen_string_literal: true

# All variable text comes from the same allowlist used for organization JSON
# and CSV. Historical records use stable record IDs when context was not saved.
class ActivityLogSentence
  def initialize(entry, actor_name:, audience: :org_owner)
    @entry, @actor = entry, actor_name
    @definition = AuditActions.organization_definition(entry.action, audience: audience)
    safe = AuditActions.organization_payload(entry.action, audience: audience, before_data: entry.before_data,
      after_data: entry.after_data, metadata: entry.metadata)
    @before, @after, @metadata = safe.values_at(:before_data, :after_data, :metadata)
  end

  def call
    if definition[:sentence_template]
      return format(definition[:sentence_template], actor: actor, event: event_name,
        tickets: value("ticket_count") ? " of #{value('ticket_count')} tickets" : "")
    end

    specific_sentence || contextual_sentence
  end

  private

  attr_reader :entry, :actor, :definition, :before, :after, :metadata

  def value(key)
    metadata[key].presence || after[key].presence || before[key].presence
  end

  def money(cents)
    return unless cents.is_a?(Numeric)

    currency = value("currency").to_s.upcase.presence || "USD"
    amount = format("%.2f", cents / 100.0)
    currency == "USD" ? "$#{amount}" : "#{amount} #{currency}"
  end

  def amount = money(value("amount_cents"))
  def record_label = "#{entry.auditable_type.to_s.underscore.humanize.downcase} ##{entry.auditable_id}"
  def subject = value("subject_label") || record_label
  def event_name = value("event_title") || "event ##{entry.event_id}"
  def order = value("order_reference") || (value("order_id") && "##{value('order_id')}")
  def role = OrganizationRoles.label(value("team_role") || value("role") || "team_member")
  def member = value("team_member_label") || value("target_name") || "team member ##{value('target_user_id') || entry.auditable_id}"

  def specific_sentence
    case entry.action
    when "payout_method.approved", "payout_method.changes_requested"
      method = value("provider") == "check" ? "check" : "bank transfer"
      organization = value("organization_name") || "organization ##{entry.organization_id}"
      entry.action == "payout_method.approved" ? "HåfaPass approved the #{method} payout method for #{organization}." :
        "HåfaPass asked for changes to the #{method} payout method for #{organization}."
    when "ticket_type.updated", "pricing_tier.updated", "catalog_item.updated"
      if before.key?("price_cents") && after.key?("price_cents") && before["price_cents"] != after["price_cents"]
        return "#{actor} changed #{subject}'s price from #{money(before['price_cents']) || 'not set'} to #{money(after['price_cents']) || 'not set'}."
      end
      inventory = %w[quantity_available quantity_limit inventory_quantity].find { |key| before.key?(key) && after.key?(key) && before[key] != after[key] }
      return "#{actor} changed #{subject}'s inventory from #{before[inventory] || 'unlimited'} to #{after[inventory] || 'unlimited'}." if inventory

      "#{actor} updated #{subject}."
    when "ticket_type.created", "pricing_tier.created", "catalog_item.created"
      "#{actor} created #{subject}#{money(value('price_cents')) && " at #{money(value('price_cents'))}"}."
    when "ticket_type.deleted", "pricing_tier.deleted", "catalog_item.deleted"
      "#{actor} deleted #{subject}."
    when "event.updated"
      detail = if before["status"] && after["status"] && before["status"] != after["status"]
        " from #{before['status'].to_s.humanize.downcase} to #{after['status'].to_s.humanize.downcase}"
      elsif before["max_capacity"] && after["max_capacity"] && before["max_capacity"] != after["max_capacity"]
        "'s capacity from #{before['max_capacity']} to #{after['max_capacity']}"
      end
      "#{actor} #{detail ? 'changed' : 'updated'} #{event_name}#{detail}."
    when /\Aguest_list\./
      verb = { "created" => "added", "updated" => "updated", "deleted" => "removed", "redeemed" => "redeemed" }.fetch(entry.action.split(".").last)
      "#{actor} #{verb} guest list entry ##{entry.auditable_id}#{value('quantity') && " (#{value('quantity')} tickets#{value('ticket_type_label') && " · #{value('ticket_type_label')}"})"} for #{event_name}."
    when "organization.ownership_transferred"
      "#{actor} transferred organization ownership to #{member}."
    when "organization.invitation_accepted"
      "#{actor} accepted a team invitation as #{role}."
    when "organization.invitation_created"
      "#{actor} invited #{member} as #{role}."
    when "organization.invitation_resent"
      "#{actor} resent #{member}'s invitation as #{role}."
    when "organization.membership_updated"
      "#{actor} changed #{member}'s team access to #{role}."
    when "organization.membership_revoked"
      "#{actor} removed #{member}'s team access."
    when "event_staff.assigned", "event_staff.updated"
      "#{actor} assigned #{member} as #{role} for #{event_name}."
    when "event_staff.revoked", "event_staff.invitation_revoked"
      "#{actor} removed #{member}'s #{role} access for #{event_name}."
    when "refund.failed", "refund.pending", "refund.succeeded", "refund.unknown", "refund.provider_result_conflict"
      result = { "failed" => "failed", "pending" => "is pending", "succeeded" => "completed", "unknown" => "needs review", "provider_result_conflict" => "has conflicting provider results" }.fetch(entry.action.split(".").last)
      "#{actor} reported that #{amount ? "a #{amount} refund" : "refund ##{entry.auditable_id}"}#{order && " for order #{order}"} #{result}."
    when "refund.created", "refund.requested", "refund.buyer_requested", "refund.submission_requested"
      "#{actor} requested #{amount ? "a #{amount} refund" : "refund ##{entry.auditable_id}"}#{order && " for order #{order}"}."
    when /\Adispute\./
      result = { "opened" => "reported", "updated" => "updated", "won" => "reported a win for", "lost" => "reported a loss for" }.fetch(entry.action.split(".").last, "updated")
      "#{actor} #{result} a dispute#{order && " on order #{order}"}#{amount && " for #{amount}"}."
    when "promo_code.created", "promo_code.updated", "promo_code.deleted"
      discount = if value("discount_value")
        value("discount_type") == "percentage" ? "#{value('discount_value')}% off" : "#{money(value('discount_value'))} off"
      end
      "#{actor} #{entry.action.split('.').last} promo code #{subject}#{discount && " (#{discount})"}."
    when /\Acampaign\./
      verb = definition[:template].sub(/\.$/, "").sub(/a campaign/, "campaign #{subject}")
      "#{actor} #{verb.sub(/\A./, &:downcase)}#{value('recipient_count') && " (#{value('recipient_count')} recipients)"}."
    when /\Acard_present\.payment/
      result = { "payment_succeeded" => "completed", "payment_failed" => "failed", "payment_result_unknown" => "needs review" }.fetch(entry.action.split(".").last)
      "#{actor} reported that #{amount ? "a #{amount} card payment" : "card payment ##{entry.auditable_id}"}#{order && " for order #{order}"} #{result}."
    when "organizer.verification_updated"
      "#{actor} changed organizer verification#{value('verification_status') && " to #{value('verification_status').to_s.humanize.downcase}"}."
    when "ticket.check_in_reversed"
      "#{actor} undid check-in for ticket ##{value('ticket_id') || entry.auditable_id} at #{event_name}."
    when "box_office.cash_sale_created"
      "#{actor} recorded #{amount ? "a #{amount} cash sale" : "a cash sale"}#{order ? " for order #{order}" : " at #{event_name}"}#{value('ticket_count') && " (#{value('ticket_count')} tickets)"}."
    end
  end

  def contextual_sentence
    text = definition[:template].sub(/\.$/, "").sub(/\A./, &:downcase)
    # Replace vague subjects without ever loading a live buyer/target record.
    text = text.sub(/\b(?:an event|event)\b/, event_name) if entry.event_id && definition[:area] == "events"
    text = text.sub(/\ba payout\b/, "#{amount ? "a #{amount} payout" : "payout ##{entry.auditable_id}"}") if definition[:area] == "payouts"
    text = text.sub(/\ba refund\b/, "#{amount ? "a #{amount} refund" : "refund ##{entry.auditable_id}"}") if definition[:area] == "refunds"
    text += " (#{value('year')})" if entry.action == "annual_tax_report.statement_downloaded" && value("year")
    text += " (certification #{value('certification_version')})" if entry.action == "organizer_tax_information.updated" && value("certification_version")
    if definition[:area] == "payout_settings"
      flags = %w[charges_enabled payouts_enabled].filter_map do |key|
        "#{key.delete_suffix('_enabled').humanize.downcase} #{after[key] ? 'enabled' : 'disabled'}" if after.key?(key) && before[key] != after[key]
      end
      text += ": #{flags.join(', ')}" if flags.any?
    end
    text += " for order #{order}" if order && %w[refunds orders].include?(definition[:area])
    text += " (#{value('row_count')} rows)" if definition[:area] == "exports" && value("row_count")
    text += " for #{event_name}" if entry.event_id && !text.include?(event_name) && %w[exports payouts attendees].include?(definition[:area])
    "#{actor} #{text}."
  end
end
