class S3Service
  class << self
    # Returns true if AWS S3 is configured with all required environment variables.
    def configured?
      ENV["AWS_ACCESS_KEY_ID"].present? &&
        ENV["AWS_SECRET_ACCESS_KEY"].present? &&
        ENV["AWS_BUCKET"].present?
    end

    # Generates a presigned POST URL for direct browser upload to S3.
    # Returns a hash with :url (the S3 bucket endpoint) and :fields (form fields to include in the POST).
    # The presigned post expires after 15 minutes.
    #
    # S3 key format: uploads/events/:event_id/:timestamp_:filename
    #
    # @param filename [String] the original filename
    # @param content_type [String] the MIME type (e.g., "image/jpeg")
    # @param event_id [Integer, String] optional event ID for key organization
    # @return [Hash] { url: String, fields: Hash, key: String } or nil if not configured
    def generate_presigned_post(filename, content_type, event_id: nil)
      return nil unless configured?

      key = build_key(filename, event_id: event_id)

      presigned_post = s3_bucket.presigned_post(
        key: key,
        content_type: content_type,
        content_length_range: 1..10.megabytes,
        expires: Time.now + 15.minutes
      )

      {
        url: presigned_post.url,
        fields: presigned_post.fields,
        key: key
      }
    end

    # Generates a time-limited (1 hour) presigned GET URL for downloading/viewing a file.
    #
    # @param key [String] the S3 object key
    # @return [String] presigned URL or nil if not configured
    def generate_presigned_get(key)
      return nil unless configured?

      signer = Aws::S3::Presigner.new(client: s3_client)
      signer.presigned_url(:get_object, bucket: bucket_name, key: key, expires_in: 3600)
    end

    private

    def s3_client
      @s3_client ||= Aws::S3::Client.new(
        region: ENV.fetch("AWS_REGION", "us-west-2"),
        credentials: Aws::Credentials.new(
          ENV["AWS_ACCESS_KEY_ID"],
          ENV["AWS_SECRET_ACCESS_KEY"]
        )
      )
    end

    def s3_bucket
      @s3_bucket ||= Aws::S3::Resource.new(client: s3_client).bucket(bucket_name)
    end

    def bucket_name
      ENV["AWS_BUCKET"]
    end

    def build_key(filename, event_id: nil)
      sanitized = filename.gsub(/[^a-zA-Z0-9._-]/, "_")
      timestamp = Time.now.to_i
      if event_id
        "uploads/events/#{event_id}/#{timestamp}_#{sanitized}"
      else
        "uploads/general/#{timestamp}_#{sanitized}"
      end
    end
  end
end
