Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Stripe webhooks (outside API namespace, no auth)
  post "webhooks/stripe", to: "webhooks#stripe"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      get "config", to: "config#show"
      get "me", to: "me#show"
      post "users/sync", to: "users#sync"

      # Organizer profile (singular resource - one per user)
      get "organizer_profile", to: "organizer_profiles#show"
      post "organizer_profile", to: "organizer_profiles#create_or_update"
      put "organizer_profile", to: "organizer_profiles#create_or_update"

      # Presigned upload URL (authenticated) - works in simulate mode too
      post "uploads/presign", to: "uploads#presign"

      # Orders (public create for guest checkout)
      resources :orders, only: [:create] do
        member do
          post :cancel
        end
      end

      # Promo code validation (public, for checkout)
      post "promo_codes/validate", to: "promo_codes#validate"

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
          resources :promo_codes, only: [:index, :show, :create, :update, :destroy]
          resources :guest_list, only: [:index, :create, :update, :destroy],
                    controller: "guest_list_entries" do
            member do
              post :redeem
            end
          end
          # Refunds for specific orders
          resources :orders, only: [] do
            member do
              post :refund, to: "refunds#create"
            end
          end
        end
      end

      # Admin endpoints
      namespace :admin do
        resource :settings, only: [:show, :update]
      end
    end
  end
end
