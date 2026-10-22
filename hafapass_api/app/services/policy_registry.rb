# frozen_string_literal: true

require "digest"
require "yaml"

class PolicyRegistry
  DOCUMENT_PATH = Rails.root.join("config/policies.yml")
  BUYER_DOCUMENT_KEYS = %w[buyer-terms privacy refunds acceptable-use retention].freeze
  # Policy text names the platform, operator, support contact and current fee
  # and payout terms through these placeholders, filled from SiteSetting when
  # served. Digests never hash the rendered text: they cover the unrendered
  # templates plus a digest of the material terms only (MATERIAL_SETTINGS).
  # Cosmetic settings (platform name, support email) therefore leave every
  # digest and approval intact, while a fee or payout-timing change is a
  # contract change: organizers re-accept and the policy register needs a new
  # approval.
  PLACEHOLDER = /\{\{([a-z_]+)\}\}/
  PLACEHOLDERS = %w[platform_name operator_name support_contact fee_schedule payout_schedule].freeze
  MATERIAL_SETTINGS = %w[service_fee_percent service_fee_flat_cents processing_fee_bearer payout_schedule_text].freeze
  # The order-recovery page cannot receive privacy or accessibility requests.
  SUPPORT_FALLBACK = "at shimizutechnology@gmail.com"
  # Drafting notes in square brackets belong in review_notes, never in the
  # public text; one left in a document is a technical blocker.
  REVIEW_MARKER = /\[[^\]\n]+\]/
  class << self
    def version
      registry.fetch("version")
    end

    def effective_date
      registry.fetch("effective_date")
    end

    # The policy owner's publication decision, independent of later professional review.
    def status
      registry.fetch("status")
    end

    # Admin-only summary. Review notes must never be included in public_documents.
    def review_summary
      {
        version: version,
        effective_date: effective_date,
        status: status,
        draft: draft?,
        registry_digest: registry_digest,
        approval_blockers: approval_blockers,
        review_notes: review_notes,
        documents: documents.map { |key, document| { key: key, title: document.fetch("title") } }
      }
    end

    def draft?
      status != "approved"
    end

    # Legal-review items kept out of the public text, per document and section.
    def review_notes
      titles = templates.transform_values { |document| document.fetch("title") }
      registry.fetch("review_notes", {}).flat_map do |key, notes|
        notes.map { |note| { document: key, title: titles.fetch(key, key), section: note.fetch("section"), note: note.fetch("note") } }
      end
    end

    # Technical problems that make the served text unfit to approve. Open
    # professional-review items are tracked internally and do not block publication.
    def approval_blockers
      blockers = []
      begin
        rendered = documents
      rescue KeyError => e
        return ["A policy uses an unknown template placeholder (#{e.key})"]
      end
      unfilled = rendered.select { |_key, document| text_of(document).match?(PLACEHOLDER) }
      blockers << "Unfilled template placeholders remain in: #{titles_of(unfilled)}" if unfilled.any?
      marked = rendered.select { |_key, document| text_of(document).match?(REVIEW_MARKER) }
      blockers << "Bracketed drafting notes remain in the public text of: #{titles_of(marked)}" if marked.any?
      blockers
    end

    # Only the settings that change what organizers and buyers agree to.
    def material_terms
      settings = SiteSetting.instance
      {
        "service_fee_percent" => settings.service_fee_percent.to_d.to_s,
        "service_fee_flat_cents" => settings.service_fee_flat_cents.to_i,
        "processing_fee_bearer" => settings.processing_fee_bearer.to_s,
        "payout_schedule_text" => settings.payout_schedule_text.to_s
      }
    end

    def material_terms_digest
      Digest::SHA256.hexdigest(JSON.generate(material_terms))
    end

    def registry_digest
      # Publication fields are included so a status or effective-date change
      # also requires a fresh approval.
      Digest::SHA256.hexdigest(JSON.generate({ "version" => version, "effective_date" => effective_date.to_s,
        "status" => status, "documents" => templates, "material_terms_digest" => material_terms_digest }))
    end

    def production_approved?
      PlatformCapabilities.enabled?("policy_register")
    end

    def buyer_terms
      snapshot(BUYER_DOCUMENT_KEYS)
    end

    def organizer_agreement
      snapshot(["organizer-agreement"])
    end

    def public_documents
      documents.deep_dup
    end

    private

    def snapshot(keys)
      content = keys.to_h { |key| [key, templates.fetch(key)] }
      canonical = JSON.generate({ "version" => version, "documents" => content,
        "material_terms_digest" => material_terms_digest })
      { version: version, digest: Digest::SHA256.hexdigest(canonical) }
    end

    def registry
      @registry ||= YAML.safe_load_file(DOCUMENT_PATH, permitted_classes: [], aliases: false).freeze
    end

    def templates
      registry.fetch("documents")
    end

    # Every string in a document, one per line, so JSON punctuation can't
    # look like a bracketed note.
    def text_of(value)
      case value
      when Hash then value.values.map { |child| text_of(child) }.join("\n")
      when Array then value.map { |child| text_of(child) }.join("\n")
      else value.to_s
      end
    end

    def titles_of(documents)
      documents.map { |_key, document| document.fetch("title") }.join(", ")
    end

    def documents
      render(templates, placeholder_values)
    end

    def render(value, values)
      case value
      when Hash then value.transform_values { |child| render(child, values) }
      when Array then value.map { |child| render(child, values) }
      when String then value.gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1)) }
      else value
      end
    end

    def placeholder_values
      settings = SiteSetting.instance
      platform_name = settings.platform_name.presence || "HåfaPass"
      {
        "platform_name" => platform_name,
        "operator_name" => SellerIdentity::OPERATOR_NAME,
        "support_contact" => settings.platform_email.present? ? "at #{settings.platform_email}" : SUPPORT_FALLBACK,
        "fee_schedule" => fee_schedule(settings, platform_name),
        "payout_schedule" => settings.payout_schedule_text
      }
    end

    def fee_schedule(settings, platform_name)
      percent = settings.service_fee_percent.to_d
      percent_text = "#{percent.frac.zero? ? percent.to_i : percent.round(2).to_s('F')}%"
      flat = settings.service_fee_flat_cents.to_i
      rate = if flat.positive?
        "#{percent_text} of each paid ticket's price plus #{UsdMoney.format_cents(flat)} per paid ticket"
      else
        "#{percent_text} of each paid ticket's price"
      end
      processing = if settings.platform_bears_processing?
        "card processing is paid by #{platform_name} out of this fee"
      else
        "card processing costs are deducted from organizer proceeds"
      end
      "#{rate}; free tickets carry no service fee; #{processing}"
    end
  end
end
