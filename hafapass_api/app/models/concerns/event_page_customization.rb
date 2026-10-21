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
    urls = page_image_urls(data).uniq
    @approved_page_image_urls = urls.empty? ? [] : ImageUploadReceipt.where(
      organization_id: organization_id, public_url: urls
    ).where.not(completed_at: nil).pluck(:public_url)
    errors.add(:page_customization, "accent must be a six-digit hex color") unless valid_accent?(data["accent"])
    errors.add(:page_customization, "focal point must have x and y between 0 and 100") unless valid_focal?(data["focal_point"])
    errors.add(:page_customization, "description format must be plain or markdown") unless [nil, "plain", "markdown"].include?(data["description_format"])
    validate_gallery_feedback(data["gallery"])
    validate_sections_feedback(data["sections"])
  rescue JSON::GeneratorError
    errors.add(:page_customization, "is invalid")
  ensure
    @approved_page_image_urls = nil
  end

  def clamp_page_focal_point
    data = page_customization
    return unless data.is_a?(Hash) && data["focal_point"].is_a?(Hash)

    focal = data["focal_point"]
    return unless %w[x y].all? { |axis| focal[axis].is_a?(Numeric) && focal[axis].finite? }

    self.page_customization = data.merge("focal_point" => focal.transform_values { |number| number.clamp(0, 100) })
  end

  def page_image_urls(data)
    gallery = data["gallery"].is_a?(Array) ? data["gallery"] : []
    sections = data["sections"].is_a?(Array) ? data["sections"] : []
    gallery.filter_map { |photo| photo["url"] if photo.is_a?(Hash) && photo["url"].is_a?(String) } +
      sections.flat_map do |section|
        next [] unless section.is_a?(Hash) && section["items"].is_a?(Array)

        section["items"].filter_map do |item|
          next unless item.is_a?(Hash)

          image_url = item["photo_url"] || item["logo_url"]
          image_url if image_url.is_a?(String)
        end
      end
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

  def validate_gallery_feedback(gallery)
    return if gallery.nil?
    return errors.add(:page_customization, "gallery must be a list of at most 8 photos") unless gallery.is_a?(Array) && gallery.size <= 8

    gallery.each_with_index do |photo, index|
      label = "gallery photo #{index + 1}"
      unless valid_fields?(photo, required: %w[url alt], optional: %w[caption])
        errors.add(:page_customization, "#{label} has missing or unknown fields")
        next unless photo.is_a?(Hash)
      end
      errors.add(:page_customization, "#{label} URL #{ApprovedImageUrl::MESSAGE}") unless valid_image?(photo["url"])
      errors.add(:page_customization, "#{label} needs alt text (up to 200 characters)") unless valid_text?(photo["alt"], 200, required: true)
      errors.add(:page_customization, "#{label} caption must be at most 300 characters") unless valid_text?(photo["caption"], 300)
    end
  end

  def validate_sections_feedback(sections)
    return if sections.nil?
    return errors.add(:page_customization, "sections must be a list of at most #{SECTION_TYPES.size}") unless sections.is_a?(Array) && sections.size <= SECTION_TYPES.size

    seen = []
    sections.each_with_index do |section, index|
      label = "section #{index + 1}"
      unless section.is_a?(Hash) && SECTION_TYPES.include?(section["type"])
        errors.add(:page_customization, "#{label} has an invalid type")
        next
      end
      type = section["type"]
      errors.add(:page_customization, "#{type} section is duplicated") if seen.include?(type)
      seen << type
      errors.add(:page_customization, "#{type} section must be enabled or disabled") unless [true, false].include?(section["enabled"])
      if type == "video"
        errors.add(:page_customization, "video section has missing or unknown fields") unless section.keys.sort == %w[enabled type url]
        if section["enabled"] ? !valid_video?(section["url"]) : section["url"] != "" && !valid_video?(section["url"])
          errors.add(:page_customization, "video URL must be a valid YouTube or Vimeo HTTPS link")
        end
        next
      end
      errors.add(:page_customization, "#{type} section has missing or unknown fields") unless section.keys.sort == %w[enabled items type]
      items = section["items"]
      unless items.is_a?(Array) && items.size <= 20
        errors.add(:page_customization, "#{type} section must have at most 20 items")
        next
      end
      if type == "gallery"
        errors.add(:page_customization, "gallery section items must be empty; use the gallery photos") unless items.empty?
        next
      end
      schema = {
        "lineup" => [%w[name], %w[role photo_url url]], "schedule" => [%w[time title], %w[note]],
        "faq" => [%w[question answer], []], "sponsors" => [%w[name logo_url], %w[url]],
        "links" => [%w[label url kind], []]
      }.fetch(type)
      items.each_with_index do |item, item_index|
        item_label = "#{type} item #{item_index + 1}"
        unless valid_fields?(item, required: schema[0], optional: schema[1])
          errors.add(:page_customization, "#{item_label} has missing or unknown fields")
          next unless item.is_a?(Hash)
        end
        item.each do |key, value|
          case key
          when "url"
            errors.add(:page_customization, "#{item_label} has an unsafe link; use an HTTPS URL") unless (schema[1].include?(key) && value.blank?) || valid_web?(value)
          when "photo_url", "logo_url"
            errors.add(:page_customization, "#{item_label} image URL #{ApprovedImageUrl::MESSAGE}") unless valid_image?(value)
          when "kind"
            errors.add(:page_customization, "#{item_label} has an invalid link kind") unless LINK_TYPES.include?(value)
          else
            errors.add(:page_customization, "#{item_label} #{key} is missing or too long") unless valid_text?(value, key == "answer" ? 1000 : 200, required: schema[0].include?(key))
          end
        end
      end
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
    ApprovedImageUrl.well_formed?(value) && @approved_page_image_urls.include?(value)
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
