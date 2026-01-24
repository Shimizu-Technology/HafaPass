# AWS S3 configuration
# Only initialize the S3 client if all required AWS environment variables are present.
# The app runs without AWS keys for development/testing (presign endpoint returns 503).
if ENV["AWS_ACCESS_KEY_ID"].present? && ENV["AWS_SECRET_ACCESS_KEY"].present? && ENV["AWS_BUCKET"].present?
  Aws.config.update(
    region: ENV.fetch("AWS_REGION", "us-west-2"),
    credentials: Aws::Credentials.new(
      ENV["AWS_ACCESS_KEY_ID"],
      ENV["AWS_SECRET_ACCESS_KEY"]
    )
  )
end
