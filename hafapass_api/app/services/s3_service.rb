# frozen_string_literal: true

class S3Service
  CONTENT_TYPES = { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp" }.freeze
  MAX_BYTES = 5.megabytes
  class UploadError < StandardError; end
  class UploadUnavailable < UploadError; end

  class << self
    def configured?
      ENV["AWS_ACCESS_KEY_ID"].present? && ENV["AWS_SECRET_ACCESS_KEY"].present? && ENV["AWS_BUCKET"].present?
    end

    def generate_presigned_post(filename, content_type, byte_size:, event_id: nil, organization_id: nil)
      validate_upload!(filename, content_type, byte_size)
      raise UploadError, "Image storage is not configured" unless configured?

      key = build_key(filename, event_id: event_id, organization_id: organization_id, prefix: "pending")
      post = s3_bucket.presigned_post(key: key, content_type: content_type,
        content_length_range: 1..Integer(byte_size), expires: Time.now + 15.minutes)
      { url: post.url, fields: post.fields, key: key, simulated: false }
    end

    # Only completion publishes a URL. Check the stored bytes and copy to a new
    # immutable key which the browser's POST policy cannot overwrite. Conditional
    # reads/copy prevent replacement of the pending object during verification.
    def complete_upload(key:, content_type:, byte_size:, event_id: nil, organization_id: nil, final_key: nil)
      validate_upload!(key, content_type, byte_size)
      object = s3_client.head_object(bucket: bucket_name, key: key)
      unless object.content_type == content_type && object.content_length == Integer(byte_size)
        raise UploadError, "The stored image does not match the selected file. Please upload it again."
      end
      bytes = s3_client.get_object(bucket: bucket_name, key: key, range: "bytes=0-15", if_match: object.etag).body.read
      raise UploadError, "Choose a valid JPG, PNG, or WebP image" unless image_signature_matches?(bytes, content_type)

      final_key ||= self.final_key(content_type: content_type, event_id: event_id, organization_id: organization_id)
      s3_client.copy_object(bucket: bucket_name, key: final_key,
        copy_source: "#{bucket_name}/#{key}", copy_source_if_match: object.etag,
        metadata_directive: "REPLACE", content_type: content_type,
        cache_control: "public, max-age=31536000, immutable")
      { key: final_key, public_url: public_url(final_key) }
    rescue Seahorse::Client::NetworkingError => error
      Rails.logger.warn("Image upload verification interrupted (#{error.class})")
      raise UploadUnavailable, "Image verification was interrupted. Please retry the upload completion."
    rescue Aws::S3::Errors::ServiceError => error
      Rails.logger.warn("Image upload verification failed (#{error.class})")
      raise UploadError, "The image could not be verified. Please upload it again."
    end

    def final_key(content_type:, event_id: nil, organization_id: nil)
      build_key("image.#{CONTENT_TYPES.fetch(content_type)}", event_id: event_id, organization_id: organization_id)
    end

    def delete_pending_upload(key)
      return unless key.start_with?("pending/")

      s3_client.delete_object(bucket: bucket_name, key: key)
    rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => error
      Rails.logger.warn("Pending image cleanup deferred to bucket lifecycle (#{error.class})")
    end

    def generate_presigned_get(key)
      raise UploadError, "Image storage is not configured" unless configured?

      Aws::S3::Presigner.new(client: s3_client).presigned_url(:get_object,
        bucket: bucket_name, key: key, expires_in: 3600)
    end

    private

    def validate_upload!(filename, content_type, byte_size)
      raise UploadError, "Choose an image file" if filename.blank?
      raise UploadError, "Choose a JPG, PNG, or WebP image" unless CONTENT_TYPES.key?(content_type)
      size = Integer(byte_size, exception: false)
      raise UploadError, "Image must be between 1 byte and 5 MB" unless size && size.between?(1, MAX_BYTES)
    end

    def image_signature_matches?(bytes, content_type)
      case content_type
      when "image/jpeg" then bytes.b.start_with?("\xFF\xD8\xFF".b)
      when "image/png" then bytes.b.start_with?("\x89PNG\r\n\x1A\n".b)
      when "image/webp" then bytes[0, 4] == "RIFF" && bytes[8, 4] == "WEBP"
      else false
      end
    end

    def s3_client
      @s3_client ||= Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
        credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"]))
    end

    def s3_bucket
      @s3_bucket ||= Aws::S3::Resource.new(client: s3_client).bucket(bucket_name)
    end

    def bucket_name
      ENV.fetch("AWS_BUCKET")
    end

    def public_url(key)
      "https://#{bucket_name}.s3.#{ENV.fetch('AWS_REGION', 'us-west-2')}.amazonaws.com/#{key}"
    end

    def build_key(filename, event_id: nil, organization_id: nil, prefix: "uploads")
      extension = File.extname(filename.to_s).delete_prefix(".").downcase
      extension = "jpg" unless %w[jpg jpeg png webp].include?(extension)
      scope = event_id ? "events/#{event_id}" : "organizations/#{organization_id}"
      "#{prefix}/#{scope}/#{SecureRandom.uuid}.#{extension}"
    end
  end
end
