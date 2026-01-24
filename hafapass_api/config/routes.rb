Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      get "me", to: "me#show"
      post "users/sync", to: "users#sync"

      # Organizer profile (singular resource - one per user)
      get "organizer_profile", to: "organizer_profiles#show"
      post "organizer_profile", to: "organizer_profiles#create_or_update"
      put "organizer_profile", to: "organizer_profiles#create_or_update"

      # Orders (public create for guest checkout)
      resources :orders, only: [:create]

      # Public ticket display (by QR code)
      get "tickets/:qr_code", to: "tickets#show", as: :ticket

      # Ticket check-in
      post "check_in/:qr_code", to: "check_ins#create", as: :check_in

      # Authenticated user endpoints
      namespace :me do
        resources :orders, only: [:index, :show]
        resources :tickets, only: [:index]
      end

      # Public events
      resources :events, only: [:index], param: :slug
      get "events/:slug", to: "events#show", as: :event

      # Organizer events (protected)
      namespace :organizer do
        resources :events, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :publish
            get :stats
            get :attendees
          end
          resources :ticket_types, only: [:index, :show, :create, :update, :destroy]
        end
      end
    end
  end
end
