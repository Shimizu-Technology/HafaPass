# CORS configuration
# Set ALLOWED_ORIGINS environment variable in production
# Example: ALLOWED_ORIGINS=https://hafapass.com,https://www.hafapass.com

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Default origins for development, override with ALLOWED_ORIGINS in production
    allowed = ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173,http://localhost:5174")
    origins(*allowed.split(",").map(&:strip))

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ["X-Total-Count", "X-Total-Pages", "X-Page", "X-Per-Page"],
      max_age: 600
  end
end
