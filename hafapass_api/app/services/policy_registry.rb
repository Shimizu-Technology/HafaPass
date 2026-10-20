# frozen_string_literal: true

require "digest"
require "yaml"

class PolicyRegistry
  DOCUMENT_PATH = Rails.root.join("config/policies.yml")
  BUYER_DOCUMENT_KEYS = %w[buyer-terms privacy refunds acceptable-use retention].freeze
  # Policy text names the platform, operator, support contact and current fee
  # and payout terms through these placeholders, filled from SiteSetting when
  # served. Digests cover the rendered text, so changing any of those settings
  # changes the served documents and requires organizers to re-accept.
  PLACEHOLDER = /\{\{([a-z_]+)\}\}/
  PLACEHOLDERS = %w[platform_name operator_name support_email fee_schedule payout_schedule].freeze
  SUPPORT_FALLBACK = "the support address on our Help page"

  class << self
    def version
      registry.fetch("version")
    end

    # Engineering status of the policy text itself ("draft-pending-legal-review"
    # until counsel supplies approved language). Not proof of approval either way.
    def status
      registry.fetch("status", "draft-pending-legal-review")
    end

    # What the admin policy register shows next to the approval controls: the
    # served version, its draft status and the documents it covers.
    def review_summary
      {
        version: version,
        status: status,
        registry_digest: registry_digest,
        documents: documents.map { |key, document| { key: key, title: document.fetch("title") } }
      }
    end

    def registry_digest
      Digest::SHA256.hexdigest(JSON.generate({ "version" => version, "documents" => documents }))
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
      content = keys.to_h { |key| [key, documents.fetch(key)] }
      canonical = JSON.generate({ "version" => version, "documents" => content })
      { version: version, digest: Digest::SHA256.hexdigest(canonical) }
    end

    def registry
      @registry ||= YAML.safe_load_file(DOCUMENT_PATH, permitted_classes: [], aliases: false).freeze
    end

    def documents
      values = placeholder_values
      render(registry.fetch("documents"), values)
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
        "support_email" => settings.platform_email.presence || SUPPORT_FALLBACK,
        "fee_schedule" => fee_schedule(settings, platform_name),
        "payout_schedule" => settings.payout_schedule_text
      }
    end

    def fee_schedule(settings, platform_name)
      percent = settings.service_fee_percent.to_d
      percent_text = "#{percent.frac.zero? ? percent.to_i : percent.round(2).to_s('F')}%"
      flat = settings.service_fee_flat_cents.to_i
      rate = if flat.positive?
        "#{percent_text} of each paid ticket's price plus $#{format('%.2f', flat / 100.0)} per paid ticket"
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
