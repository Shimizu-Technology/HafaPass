# frozen_string_literal: true

module Wallet
  # Brings saved wallet passes in line with their ticket: Apple devices get a
  # push and fetch the latest pass from the PassKit web service; Google objects
  # are replaced through the REST API. Each provider is a no-op until its
  # approval gate is enabled.
  class PassSync
    class Error < StandardError; end
    class RetryableError < Error; end

    class << self
      # Queue a sync for every recorded pass of the given ticket ids or ticket
      # relation. Jobs are enqueued after the surrounding transaction commits.
      def tickets_changed(tickets)
        WalletPass.where(ticket_id: tickets).ids.each { |id| WalletPassSyncJob.perform_later(id) }
      end

      # Events can have thousands of saved passes; one job fans them out in
      # batches instead of enqueueing every pass inside the organizer's request.
      def event_changed(event)
        WalletPassFanoutJob.perform_later(event.id) if WalletPass.where(ticket_id: event.tickets.select(:id)).exists?
      end

      def call(wallet_pass)
        wallet_pass.apple? ? sync_apple(wallet_pass) : sync_google(wallet_pass)
      end

      # Recompute the visible content; true when it changed since last recorded.
      def refresh_apple_content!(wallet_pass)
        wallet_pass.with_lock { wallet_pass.record_content!(ApplePassGenerator.content_digest(wallet_pass)) }
      end

      private

      def sync_apple(wallet_pass)
        return :disabled unless ApplePassGenerator.enabled?

        refresh_apple_content!(wallet_pass)
        return :current unless wallet_pass.sync_pending?

        digest = wallet_pass.content_digest
        results = ApplePushNotifier.call(wallet_pass.apple_wallet_registrations.pluck(:push_token))
        gone = results.select { |_token, result| result.gone? }.keys
        wallet_pass.apple_wallet_registrations.where(push_token: gone).delete_all if gone.any?
        failed = results.reject { |_token, result| result.delivered? || result.gone? }
        if failed.any?
          statuses = failed.values.map { |result| [result.status, result.reason].compact.join(" ") }.uniq.join(", ")
          retryable = failed.values.any? { |result| result.status.to_i == 429 || result.status.to_i >= 500 }
          raise (retryable ? RetryableError : Error), "Apple push failed: #{statuses}"
        end

        mark_synced!(wallet_pass, digest)
        :pushed
      end

      def sync_google(wallet_pass)
        return :disabled unless GoogleSaveLink.enabled?

        object = GoogleTicketObject.new(wallet_pass)
        digest = object.content_digest
        wallet_pass.with_lock { wallet_pass.record_content!(digest) }
        return :current unless wallet_pass.sync_pending?

        client = GoogleWalletClient.new
        response = client.update_object(object.ticket_object)
        if response.status == 404
          # Never saved. An invalid pass is created deactivated so an old save
          # link cannot later add it with a working barcode.
          unless wallet_pass.state.barcode?
            class_response = client.insert_class(object.event_class)
            GoogleWalletClient.raise_for(class_response, "class insert") unless class_response.status == 409
            response = client.insert_object(object.ticket_object)
            response = GoogleWalletClient::Response.new(status: 200, body: "") if response.status == 409
          end
          response = GoogleWalletClient::Response.new(status: 200, body: "") if response.status == 404
        end
        GoogleWalletClient.raise_for(response, "object update")

        mark_synced!(wallet_pass, digest)
        :updated
      end

      def mark_synced!(wallet_pass, digest)
        wallet_pass.update!(synced_digest: digest, synced_at: Time.current, sync_attempts: 0, last_error: nil)
      end
    end
  end
end
