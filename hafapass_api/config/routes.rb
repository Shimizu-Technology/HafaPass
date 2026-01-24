Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      get "me", to: "me#show"
      post "users/sync", to: "users#sync"
    end
  end
end
