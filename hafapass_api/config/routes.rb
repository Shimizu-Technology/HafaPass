Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Dynamic sitemap for search engines
  get "sitemap.xml", to: "sitemaps#show", defaults: { format: :xml }

  # OG meta tags for social media crawlers (serves HTML with OG tags + JS redirect)
  get "og/events/:slug", to: "og#event", as: :og_event
  get "og/policies/:slug", to: "og#policy", as: :og_policy

  # Stripe webhooks (outside API namespace, no auth)
  post "webhooks/stripe", to: "webhooks#stripe"
  post "webhooks/resend", to: "resend_webhooks#create"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      get "readiness", to: "health#readiness"
      get "config", to: "config#show"
      get "marketing/unsubscribe/:token", to: "marketing_unsubscribes#show", as: :marketing_unsubscribe
      post "marketing/unsubscribe/:token", to: "marketing_unsubscribes#create"
      get "me", to: "me#show"
      post "users/sync", to: "users#sync"

      # Organizer profile (singular resource - one per user)
      get "organizer_profile", to: "organizer_profiles#show"
      post "organizer_profile", to: "organizer_profiles#create_or_update"
      put "organizer_profile", to: "organizer_profiles#create_or_update"
      post "organizer_profile/accept_policy", to: "organizer_profiles#accept_policy"
      post "organizer_profile/submit_verification", to: "organizer_profiles#submit_verification"
      post "organization_invitations/accept", to: "organization_invitations#accept"
      post "platform_invitations/accept", to: "platform_invitations#accept"

      # Presigned upload URL (authenticated) - works in simulate mode too
      post "uploads/presign", to: "uploads#presign"
      post "uploads/complete", to: "uploads#complete"

      # Orders (public create for guest checkout)
      resources :orders, only: [:create, :show] do
        member do
          get :receipt
          post :payment_resume
          post :cancel
          post :resend
          post :event_change_response
          post "tickets/:ticket_id/rotate_scan", to: "orders#rotate_scan", as: :rotate_ticket_scan
          post "tickets/:ticket_id/cancel", to: "orders#cancel_ticket", as: :cancel_ticket
          post "tickets/:ticket_id/transfer", to: "orders#create_transfer", as: :create_ticket_transfer
          delete "tickets/:ticket_id/transfer", to: "orders#cancel_transfer", as: :cancel_ticket_transfer
          post "tickets/:ticket_id/exchange_seat", to: "orders#exchange_seat", as: :exchange_ticket_seat
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

      # Ticket PDFs fetched by the email provider when it sends a ticket email.
      get "ticket_email_attachments/:token", to: "ticket_email_attachments#show", format: false,
        constraints: { token: /[A-Za-z0-9_\-=]+--[A-Za-z0-9_\-=]+/ }

      # Apple PassKit web service (Apple appends /v1/... to the pass's webServiceURL).
      scope "wallet/apple/v1", controller: "apple_wallet_web_service", format: false,
        constraints: { pass_type_identifier: /[A-Za-z0-9.\-]+/, serial_number: /[A-Za-z0-9.\-]+/,
          device_library_identifier: /[A-Za-z0-9.\-_]+/ } do
        post "devices/:device_library_identifier/registrations/:pass_type_identifier/:serial_number", action: :register
        delete "devices/:device_library_identifier/registrations/:pass_type_identifier/:serial_number", action: :unregister
        get "devices/:device_library_identifier/registrations/:pass_type_identifier", action: :serial_numbers
        get "passes/:pass_type_identifier/:serial_number", action: :latest_pass
        post "log", action: :log
      end

      # Ticket check-in
      post "check_in/:credential", to: "check_ins#create", as: :check_in

      # Authenticated user endpoints
      namespace :me do
        resources :privacy_requests, only: [:index, :create]
        resources :orders, only: [:index, :show] do
          collection { post :recover_guest }
        end
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
      post "guest_privacy_requests", to: "guest_privacy_requests#create"
      post "guest_privacy_requests/:id/verify", to: "guest_privacy_requests#verify"
      get "privacy_export", to: "privacy_exports#show"

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
      get "events/:slug/seating", to: "event_seating#show"
      post "events/:slug/seat_holds", to: "event_seating#create_hold"
      delete "events/:slug/seat_holds", to: "event_seating#destroy_hold"
      resources :marketplace_collections, only: [:index, :show], param: :slug
      resources :venues, only: [:index, :show], param: :slug
      resources :organizers, only: [:index, :show], param: :slug
      get "distribution_links/:code", to: "distribution_links#show"
      get "event_referrals/:code", to: "event_referrals#show"
      resources :marketplace_funnel_events, only: [:create]

      # Organizer events (protected)
      namespace :organizer do
        post "fee_change_notices/:id/acknowledge", to: "fee_change_notices#acknowledge"
        get "refund_reconciliation", to: "refund_reconciliations#index"
        post "refund_reconciliation/:type/:id/:operation", to: "refund_reconciliations#action"
        resource :tax_information, only: [:show, :update]
        resource :organization, only: [:show], controller: "organizations"
        resource :finances, only: [:show], controller: "organization_finances" do
          get :orders_export
          get :payouts_export
        end
        resources :organizations, only: [:index]
        resources :memberships, only: [:index, :create, :update, :destroy] do
          member do
            post :resend
            post :invitation_link
            post :transfer_ownership
          end
        end
        resources :connected_accounts, only: [:index, :create, :update]
        resources :venue_layouts, only: [:index, :show, :create, :update]
        resource :card_present_account, only: [:show]
        resources :events, only: [:index, :show, :create, :update, :destroy] do
          collection do
            get :summary
          end
          member do
            post :publish
            post :postpone
            post :resume
            post :cancel
            get :cancellation_refunds
            post :retry_cancellation_refunds
            post "cancellation_refunds/:order_id/mark_cash_refunded", to: "events#mark_cash_refunded"
            post :complete
            post :archive
            post :clone
            post :generate_recurrences
            get :stats
            get :attendees
            get :slug_availability
            post :retranslate
          end
          resources :ticket_types, only: [:index, :show, :create, :update, :destroy] do
            resources :pricing_tiers, only: [:index, :create, :update, :destroy]
          end
          resources :promo_codes, only: [:index, :show, :create, :update, :destroy]
          resources :staff_assignments, only: [:index, :create, :update, :destroy],
                    controller: "event_staff_assignments"
          post "staff_invitations/:membership_id/resend", to: "event_staff_assignments#resend_invitation"
          delete "staff_invitations/:membership_id", to: "event_staff_assignments#revoke_invitation"
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
            get :orders_export
            get :statement_export
          end
          # Box Office (door sales)
          resource :box_office, only: [:create], controller: "box_office" do
            get :summary
          end
          resource :seating, only: [:show, :create], controller: "event_seating" do
            post :suspend
            post :resume
            post :release_accessible
            post :update_seat_statuses
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
          post "attendees/:ticket_id/resend", to: "attendee_deliveries#create", as: :resend_attendee_ticket
          post "sales_exports", to: "sales_exports#create"
          get "sales_exports", to: "sales_exports#index"
          get "sales_exports/door_list", to: "sales_exports#door_list"
          get "sales_exports/:id", to: "sales_exports#show"
          get "crm/export", to: "crm#export"
          get "crm/segments", to: "crm#segments"
          post "catalog_fulfillments/:order_item_id", to: "catalog_fulfillments#create"
          # Refunds for specific orders
          resources :orders, only: [:index] do
            member do
              post :refund, to: "refunds#create"
            end
          end
        end
      end

      # Admin endpoints
      namespace :admin do
        resources :legal_holds, only: [:index, :create] do
          post :release, on: :member
        end
        resources :privacy_requests, only: [:index, :show] do
          member do
            post :verify
            post :execute
            get :export
          end
        end
        get "refund_reconciliation", to: "refund_reconciliations#index"
        post "refund_reconciliation/:type/:id/:operation", to: "refund_reconciliations#action"
        resource :tax_reports, only: [:show] do
          get :organizers_export
          get :receipts_export
          post :preparation_export
        end
        post "organizations/:organization_id/tax_information/reveal", to: "tax_informations#reveal"
        resource :settings, only: [:show, :update]
        get "settings/fee_change_preview", to: "settings#fee_change_preview"
        resource :dashboard, only: [:show], controller: "dashboard"
        resources :events, only: [:index, :update] do
          member do
            get :cancellation_refunds
            post :cancel_and_refund
            post :start_cancellation_refunds
            post :retry_cancellation_refunds
            post "cancellation_refunds/:order_id/mark_cash_refunded", to: "events#mark_cash_refunded"
            post "cancellation_refunds/:order_id/mark_card_refunded", to: "events#mark_card_refunded"
          end
          resource :policy_hold, only: [:create, :destroy], controller: "event_policy_holds"
          resource :sales_suspension, only: [:destroy], controller: "event_sales_suspensions"
          post :retranslate, on: :member
        end
        get "events/:event_id/pilot_readiness", to: "pilot_readiness_reviews#show"
        post "events/:event_id/pilot_readiness_reviews", to: "pilot_readiness_reviews#create"
        resources :pilot_readiness_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        get "events/:event_id/pilot_validation", to: "pilot_validation_reviews#show"
        post "events/:event_id/pilot_validation_reviews", to: "pilot_validation_reviews#create"
        resources :pilot_validation_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        get "events/:event_id/event_day_rehearsal", to: "event_day_rehearsal_reviews#show"
        post "events/:event_id/event_day_rehearsal_reviews", to: "event_day_rehearsal_reviews#create"
        resources :event_day_rehearsal_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        get "events/:event_id/live_money_proof", to: "live_money_proof_reviews#show"
        post "events/:event_id/live_money_proof_authorizations", to: "live_money_proof_authorizations#create"
        resources :live_money_proof_authorizations, only: [] do
          member do
            post :approve
            post :revoke
          end
        end
        post "events/:event_id/live_money_proof_reviews", to: "live_money_proof_reviews#create"
        resources :live_money_proof_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        get "events/:event_id/live_pilot", to: "live_pilot_reviews#show"
        post "events/:event_id/live_pilot_reviews", to: "live_pilot_reviews#create"
        resources :live_pilot_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
            post :start, to: "live_pilot_runs#start"
          end
        end
        resources :live_pilot_runs, only: [] do
          member do
            post :pause
            post :resume
            post :complete
            post :abort
            post :checkpoint
            post :incidents, to: "live_pilot_incidents#create"
          end
        end
        resources :live_pilot_incidents, only: [] do
          member { post :resolve }
        end
        get "events/:event_id/pilot_closeout", to: "pilot_closeout_reviews#show"
        post "events/:event_id/pilot_closeout_reviews", to: "pilot_closeout_reviews#create"
        resources :pilot_closeout_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        resources :users, only: [:index, :update]
        resources :platform_invitations, only: [:index, :create, :destroy] do
          member { post :resend }
        end
        resources :organizations, only: [:index, :show, :create] do
          resources :memberships, only: [:index, :create, :update, :destroy], controller: "organization_memberships" do
            member do
              post :resend
              post :invitation_link
              post :transfer_ownership
            end
          end
        end
        resources :organizer_profiles, only: [:update]
        resources :orders, only: [:index]
        resources :connected_accounts, only: [:update] do
          resources :payment_readiness_reviews, only: [:create]
        end
        resources :payment_readiness_reviews, only: [] do
          member do
            patch :approve
            post :revoke
            post :reject
          end
        end
        resources :platform_capabilities, only: [:index]
        post "platform_capabilities/:capability/reviews", to: "platform_capability_reviews#create"
        post "platform_capabilities/:capability/quick_approve", to: "platform_capability_reviews#quick_approve"
        resources :platform_capability_reviews, only: [] do
          member do
            post :approve
            post :revoke
            post :reject
          end
        end
        resources :card_present_accounts, only: [:create, :update]
        resources :balance_adjustments, only: [:index, :create, :destroy]
        resources :payouts, only: [:index, :update] do
          post :release_hold, on: :member
        end
        resources :disputes, only: [:index]
        resources :audit_logs, only: [:index]
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
