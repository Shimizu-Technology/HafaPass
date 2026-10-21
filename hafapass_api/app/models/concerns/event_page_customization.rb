# frozen_string_literal: true

module EventPageCustomization
  SECTION_TYPES = %w[lineup schedule faq sponsors video links gallery].freeze
  LINK_TYPES = %w[website instagram facebook tiktok youtube other].freeze
  WEB_URL = %r{\Ahttps://[^\s<>"']+\z}i

  private

  def page_customization_is_valid
    data = page_customization
    return errors.add(:page_customization, "must be an object") unless data.is_a?(Hash)
    return errors.add(:page_customization, "is too large") if data.to_json.bytesize > 32.kilobytes
    return errors.add(:page_customization, "has unknown fields") unless (data.keys - %w[accent focal_point description_format gallery sections]).empty?
    return if valid_accent?(data["accent"]) && valid_focal?(data["focal_point"]) &&
      [nil, "plain", "markdown"].include?(data["description_format"]) &&
      valid_gallery?(data["gallery"]) && valid_sections?(data["sections"])

    errors.add(:page_customization, "is invalid; image URLs #{ApprovedImageUrl::MESSAGE}")
  rescue JSON::GeneratorError
    errors.add(:page_customization, "is invalid")
  end

  def valid_accent?(value)
    value.nil? || value.is_a?(String) && value.match?(/\A#[0-9a-fA-F]{6}\z/)
  end

  def valid_focal?(value)
    value.nil? || value.is_a?(Hash) && value.keys.sort == %w[x y] &&
      value.values.all? { |number| number.is_a?(Numeric) && number.between?(0, 100) }
  end

  def valid_gallery?(value)
    value.nil? || value.is_a?(Array) && value.size <= 8 && value.all? do |photo|
      valid_fields?(photo, required: %w[url alt], optional: %w[caption]) &&
        valid_image?(photo["url"]) && valid_text?(photo["alt"], 200, required: true) &&
        valid_text?(photo["caption"], 300)
    end
  end

  def valid_sections?(value)
    return true if value.nil?
    return false unless value.is_a?(Array) && value.size <= SECTION_TYPES.size
    return false unless value.all? { |section| section.is_a?(Hash) && SECTION_TYPES.include?(section["type"]) }
    return false unless value.map { |section| section["type"] }.uniq.size == value.size

    value.all? do |section|
      type = section["type"]
      next false unless valid_fields?(section, required: %w[type enabled], optional: %w[items url]) && [true, false].include?(section["enabled"])
      if type == "video"
        section.keys.sort == %w[enabled type url] && (section["enabled"] ? valid_video?(section["url"]) : section["url"] == "" || valid_video?(section["url"]))
      else
        section.keys.sort == %w[enabled items type] && valid_items?(type, section["items"])
      end
    end
  end

  def valid_items?(type, items)
    return false unless items.is_a?(Array) && items.size <= 20
    return items.empty? if type == "gallery"

    schema = {
      "lineup" => [%w[name], %w[role photo_url url]],
      "schedule" => [%w[time title], %w[note]],
      "faq" => [%w[question answer], []],
      "sponsors" => [%w[name logo_url], %w[url]],
      "links" => [%w[label url kind], []]
    }[type]
    return false unless schema
    items.all? do |item|
      next false unless valid_fields?(item, required: schema[0], optional: schema[1])
      item.all? do |key, val|
        case key
        when "url" then (schema[1].include?(key) && val.blank?) || valid_web?(val)
        when "photo_url", "logo_url" then valid_image?(val)
        when "kind" then LINK_TYPES.include?(val)
        else valid_text?(val, key == "answer" ? 1000 : 200, required: schema[0].include?(key))
        end
      end
    end
  end

  def valid_fields?(hash, required:, optional:)
    hash.is_a?(Hash) && (required - hash.keys).empty? && (hash.keys - required - optional).empty?
  end

  def valid_text?(value, limit, required: false)
    value.nil? && !required || value.is_a?(String) && value.length <= limit && (!required || value.strip.present?)
  end

  def valid_image?(value)
    ApprovedImageUrl.valid?(value, organization_id: organization_id)
  end

  def valid_web?(value)
    value.is_a?(String) && value.length <= 2048 && value.match?(WEB_URL) &&
      (uri = URI.parse(value)).is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end

  def valid_video?(value)
    return false unless valid_web?(value)
    uri = URI.parse(value)
    %w[youtube.com www.youtube.com youtu.be www.youtu.be vimeo.com www.vimeo.com].include?(uri.host.downcase) &&
      (uri.host.include?("vimeo") ? uri.path.match?(%r{\A/\d+/?\z}) :
        uri.host.include?("youtu.be") ? uri.path.match?(%r{\A/[\w-]{11}/?\z}) :
        uri.path == "/watch" && URI.decode_www_form(uri.query.to_s).any? { |key, id| key == "v" && id.match?(/\A[\w-]{11}\z/) })
  rescue ArgumentError, URI::InvalidURIError
    false
  end
end
