# frozen_string_literal: true

# Provider-controlled tags are evidence only after signature verification. Keep
# one bounded marker, never arbitrary tag values, in the retained safe payload.
class MessageReceiptProvenance
  APPLICATIONS = %w[hafapass csg_learn].freeze
  BENIGN_EVENTS = %w[email.sent email.delivered].freeze

  def self.application(tags)
    value = if tags.is_a?(Hash) && tags.size <= 20 && tags.all? { |key, item| valid_tag?(key, item) }
      tags["application"]
    elsif tags.is_a?(Array) && tags.size <= 20 && tags.all? { |tag| tag.is_a?(Hash) && tag.keys.sort == %w[name value] && valid_tag?(tag["name"], tag["value"]) }
      markers = tags.select { |tag| tag["name"] == "application" }
      markers.sole["value"] if markers.size == 1
    end
    value if value.is_a?(String) && APPLICATIONS.include?(value)
  end

  def self.valid_tag?(name, value)
    name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) &&
      value.is_a?(String) && value.length.between?(1, 256) && !value.match?(/[[:cntrl:]]/)
  end
  private_class_method :valid_tag?
end
