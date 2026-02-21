Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # OG meta tags for social media crawlers (serves HTML with OG tags + JS redirect)
  get "og/events/:slug", to: "og#event", as: :og_event

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
      get "tickets/:qr_code/download", to: "tickets#download", as: :ticket_download
      get "tickets/:qr_code/wallet/apple", to: "tickets#apple_wallet", as: :ticket_apple_wallet
      get "tickets/:qr_code/wallet/google", to: "tickets#google_wallet", as: :ticket_google_wallet

      # Ticket check-in
      post "check_in/:qr_code", to: "check_ins#create", as: :check_in

      # Authenticated user endpoints
      namespace :me do
        resources :orders, only: [:index, :show]
        resources :tickets, only: [:index]
      end

      # Public events
      resources :events, only: [:index], param: :slug do
        member do
          post 'waitlist', to: 'waitlist#create'
          get 'waitlist/status', to: 'waitlist#status'
          delete 'waitlist', to: 'waitlist#destroy'
        end
      end
      get "events/:slug", to: "events#show", as: :event

      # Organizer events (protected)
      namespace :organizer do
        resources :events, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :publish
            post :clone
            post :generate_recurrences
            get :stats
            get :attendees
          end
          resources :ticket_types, only: [:index, :show, :create, :update, :destroy]
          resources :promo_codes, only: [:index, :show, :create, :update, :destroy]
          # Box Office (door sales)
          resource :box_office, only: [:create], controller: "box_office" do
            get :summary
          end
          resources :guest_list, only: [:index, :create, :update, :destroy],
                    controller: "guest_list_entries" do
            member do
              post :redeem
            end
          end
          # Waitlist management
          resources :waitlist, only: [:index, :destroy], controller: "waitlist" do
            member do
              post :notify
            end
            collection do
              post :notify_next
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
        resource :dashboard, only: [:show], controller: 'dashboard'
        resources :events, only: [:index, :update]
        resources :users, only: [:index, :update]
        resources :orders, only: [:index]

        # Maintenance
        post "maintenance/complete_past_events", to: "maintenance#complete_past_events"
      end
    end
  end
end
