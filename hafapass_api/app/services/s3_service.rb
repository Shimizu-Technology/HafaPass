# frozen_string_literal: true

class S3Service
  class << self
    # Returns true if AWS S3 is configured with all required environment variables.
    def configured?
      ENV["AWS_ACCESS_KEY_ID"].present? &&
        ENV["AWS_SECRET_ACCESS_KEY"].present? &&
        ENV["AWS_BUCKET"].present?
    end

    # Generates a presigned POST URL for direct browser upload to S3.
    # In simulate mode (no AWS keys), returns fake presigned data that the
    # frontend can use to show the upload flow. When real keys are added, it just works.
    def generate_presigned_post(filename, content_type, event_id: nil)
      key = build_key(filename, event_id: event_id)

      unless configured?
        Rails.logger.info("[S3Service SIMULATE] Presigned POST for key=#{key} content_type=#{content_type}")
        return {
          url: "https://simulated-bucket.s3.amazonaws.com",
          fields: {
            key: key,
            "Content-Type" => content_type,
            policy: "simulated_policy_#{SecureRandom.hex(8)}",
            "x-amz-credential" => "SIMULATED/20260201/us-west-2/s3/aws4_request",
            "x-amz-signature" => "sim_#{SecureRandom.hex(32)}"
          },
          key: key,
          public_url: "https://simulated-bucket.s3.us-west-2.amazonaws.com/#{key}",
          simulated: true
        }
      end

      presigned_post = s3_bucket.presigned_post(
        key: key,
        content_type: content_type,
        content_length_range: 1..10.megabytes,
        expires: Time.now + 15.minutes
      )

      {
        url: presigned_post.url,
        fields: presigned_post.fields,
        key: key,
        public_url: "https://#{bucket_name}.s3.#{ENV.fetch('AWS_REGION', 'us-west-2')}.amazonaws.com/#{key}",
        simulated: false
      }
    end

    # Generates a time-limited (1 hour) presigned GET URL.
    # In simulate mode, returns a placeholder URL.
    def generate_presigned_get(key)
      unless configured?
        Rails.logger.info("[S3Service SIMULATE] Presigned GET for key=#{key}")
        return "https://simulated-bucket.s3.us-west-2.amazonaws.com/#{key}?simulated=true"
      end

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
