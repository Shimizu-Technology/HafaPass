# CORS configuration
# Every deployed environment (staging and production) must list its browser
# origins in ALLOWED_ORIGINS, e.g. ALLOWED_ORIGINS=https://tickets.example.com
# Only local development and test fall back to the local Vite ports.
require Rails.root.join("config/runtime_configuration").to_s

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*RuntimeConfiguration.allowed_origins(local: Rails.env.local?))

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ["X-Total-Count", "X-Total-Pages", "X-Page", "X-Per-Page"],
      max_age: 600
  end
end
