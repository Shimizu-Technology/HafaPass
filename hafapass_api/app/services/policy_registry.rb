# frozen_string_literal: true

require "digest"
require "yaml"

class PolicyRegistry
  DOCUMENT_PATH = Rails.root.join("config/policies.yml")
  BUYER_DOCUMENT_KEYS = %w[buyer-terms privacy refunds acceptable-use retention].freeze

  class << self
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

    def version
      registry.fetch("version")
    end

    def documents
      registry.fetch("documents")
    end
  end
end
