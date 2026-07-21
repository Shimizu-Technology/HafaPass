Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Dynamic sitemap for search engines
  get "sitemap.xml", to: "sitemaps#show", defaults: { format: :xml }

  # OG meta tags for social media crawlers (serves HTML with OG tags + JS redirect)
  get "og/events/:slug", to: "og#event", as: :og_event

  # Stripe webhooks (outside API namespace, no auth)
  post "webhooks/stripe", to: "webhooks#stripe"
  post "webhooks/resend", to: "resend_webhooks#create"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      get "readiness", to: "health#readiness"
      get "config", to: "config#show"
      get "me", to: "me#show"
      post "users/sync", to: "users#sync"

      # Organizer profile (singular resource - one per user)
      get "organizer_profile", to: "organizer_profiles#show"
      post "organizer_profile", to: "organizer_profiles#create_or_update"
      put "organizer_profile", to: "organizer_profiles#create_or_update"
      post "organizer_profile/accept_policy", to: "organizer_profiles#accept_policy"
      post "organizer_profile/submit_verification", to: "organizer_profiles#submit_verification"
      post "organization_invitations/accept", to: "organization_invitations#accept"

      # Presigned upload URL (authenticated) - works in simulate mode too
      post "uploads/presign", to: "uploads#presign"

      # Orders (public create for guest checkout)
      resources :orders, only: [:create, :show] do
        member do
          post :cancel
          post :resend
          post :event_change_response
          post "tickets/:ticket_id/rotate_scan", to: "orders#rotate_scan", as: :rotate_ticket_scan
          post "tickets/:ticket_id/cancel", to: "orders#cancel_ticket", as: :cancel_ticket
          post "tickets/:ticket_id/transfer", to: "orders#create_transfer", as: :create_ticket_transfer
          delete "tickets/:ticket_id/transfer", to: "orders#cancel_transfer", as: :cancel_ticket_transfer
        end
      end
      post "order_lookup", to: "order_recovery#create"
      get "waitlist_offers/:token", to: "waitlist_offers#show"

      # Promo code validation (public, for checkout)
      post "promo_codes/validate", to: "promo_codes#validate"

      # Public ticket display (by QR code)
      get "tickets/:credential", to: "tickets#show", as: :ticket
      get "tickets/:credential/download", to: "tickets#download", as: :ticket_download
      get "tickets/:credential/wallet/apple", to: "tickets#apple_wallet", as: :ticket_apple_wallet
      get "tickets/:credential/wallet/google", to: "tickets#google_wallet", as: :ticket_google_wallet

      # Ticket check-in
      post "check_in/:credential", to: "check_ins#create", as: :check_in

      # Authenticated user endpoints
      namespace :me do
        resources :orders, only: [:index, :show]
        resources :tickets, only: [:index]
        post "ticket_transfers/accept", to: "ticket_transfers#accept"
        post "tickets/:ticket_id/transfer", to: "ticket_transfers#create"
        delete "tickets/:ticket_id/transfer", to: "ticket_transfers#destroy"
        resources :event_favorites, only: [:index, :create] do
          collection { delete ":event_id", action: :destroy }
        end
        resources :organizer_follows, only: [:index, :create] do
          collection { delete ":organization_id", action: :destroy }
        end
        resources :event_reminders, only: [:index, :create] do
          collection { delete ":event_id", action: :destroy }
        end
        resources :event_referrals, only: [:index, :create]
      end

      # Public events
      resources :events, only: [:index], param: :slug do
        member do
          post "waitlist", to: "waitlist#create"
          get "waitlist/status", to: "waitlist#status"
          delete "waitlist", to: "waitlist#destroy"
        end
      end
      get "event_categories", to: "events#categories"
      get "events/:slug", to: "events#show", as: :event
      resources :marketplace_collections, only: [:index, :show], param: :slug
      resources :venues, only: [:index, :show], param: :slug
      resources :organizers, only: [:index, :show], param: :slug
      get "distribution_links/:code", to: "distribution_links#show"
      get "event_referrals/:code", to: "event_referrals#show"
      resources :marketplace_funnel_events, only: [:create]

      # Organizer events (protected)
      namespace :organizer do
        resource :organization, only: [:show], controller: "organizations"
        resources :organizations, only: [:index]
        resources :memberships, only: [:index, :create, :update, :destroy]
        resources :connected_accounts, only: [:index, :create]
        resource :card_present_account, only: [:show]
        resources :events, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :publish
            post :postpone
            post :resume
            post :cancel
            post :complete
            post :archive
            post :clone
            post :generate_recurrences
            get :stats
            get :attendees
          end
          resources :ticket_types, only: [:index, :show, :create, :update, :destroy] do
            resources :pricing_tiers, only: [:index, :create, :update, :destroy]
          end
          resources :promo_codes, only: [:index, :show, :create, :update, :destroy]
          resources :staff_assignments, only: [:index, :create, :update, :destroy],
                    controller: "event_staff_assignments"
          resources :scanner_devices, only: [:index, :create, :update, :destroy] do
            member do
              get :manifest
              post :sync
            end
          end
          resource :admissions, only: [:show], controller: "admissions" do
            get :search
            get :door_list
          end
          resource :finance, only: [:show], controller: "finances" do
            post :finalize
            post :payout
          end
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
              post :offer
            end
            collection do
              post :notify_next
            end
          end
          resources :catalog_items, except: [:show]
          resources :registration_questions, except: [:show]
          resources :event_waivers, except: [:show]
          resources :promoters, except: [:show]
          resources :communication_campaigns, only: [:index, :create, :update, :destroy] do
            member { post :send_now }
          end
          get "crm/export", to: "crm#export"
          get "crm/segments", to: "crm#segments"
          post "catalog_fulfillments/:order_item_id", to: "catalog_fulfillments#create"
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
        resource :dashboard, only: [:show], controller: "dashboard"
        resources :events, only: [:index, :update]
        resources :users, only: [:index, :update]
        resources :organizer_profiles, only: [:update]
        resources :orders, only: [:index]
        resources :connected_accounts, only: [:update]
        resources :card_present_accounts, only: [:create, :update]
        resources :balance_adjustments, only: [:create, :destroy]
        resources :payouts, only: [:update]
        resource :marketplace, only: [:show], controller: "marketplace"
        resources :marketplace_collections, except: [:show]
        resources :distribution_partners, except: [:show]
        resources :distribution_links, except: [:show]
        resources :venues, except: [:show]

        # Maintenance
        post "maintenance/complete_past_events", to: "maintenance#complete_past_events"
      end

      namespace :support do
        get "search", to: "search#index"
        resources :message_deliveries, only: [:index] do
          member { post :resend }
          collection { post "orders/:order_id/fulfill", to: "message_deliveries#fulfill" }
        end
        resources :notes, only: [:index, :create]
      end
    end
  end
end
