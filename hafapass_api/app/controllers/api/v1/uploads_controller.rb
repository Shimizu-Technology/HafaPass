# frozen_string_literal: true

module Api
  module V1
    class UploadsController < ApplicationController
      rescue_from S3Service::UploadError do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end

      def presign
        scope = authorized_scope(event_id: params[:event_id])
        return unless scope
        return uploads_unavailable unless S3Service.configured?

        result = S3Service.generate_presigned_post(params[:filename], params[:content_type],
          byte_size: params[:byte_size], event_id: scope[:event_id], organization_id: scope[:organization_id])
        token = SignedCredential.issue(namespace: "image_upload", expires_at: 15.minutes.from_now,
          payload: { user_id: current_user.id, key: result[:key], content_type: params[:content_type],
            byte_size: Integer(params[:byte_size]), **scope })
        render json: result.merge(upload_token: token)
      end

      def complete
        payload = SignedCredential.verify(namespace: "image_upload", token: params[:upload_token])
        unless payload && payload["user_id"] == current_user.id
          return render json: { error: "Upload authorization is invalid or expired. Choose the image again." },
            status: :unprocessable_entity
        end
        scope = authorized_scope(event_id: payload["event_id"], organization_id: payload["organization_id"])
        return unless scope
        return uploads_unavailable unless S3Service.configured?

        render json: S3Service.complete_upload(key: payload.fetch("key"),
          content_type: payload.fetch("content_type"), byte_size: payload.fetch("byte_size"), **scope)
      end

      private

      def uploads_unavailable
        render json: { error: "Image uploads are not available yet. You can save your details without an image." },
          status: :service_unavailable
      end

      def authorized_scope(event_id: nil, organization_id: nil)
        if event_id.present?
          event = Event.find_by(id: event_id)
          organization = event&.organization
          allowed = organization && OrganizationAuthorization.allowed?(user: current_user,
            organization: organization, permission: :edit_event_content, event: event)
        else
          organization = OrganizationContext.resolve(user: current_user,
            requested_id: organization_id.presence || request.headers["X-Organization-Id"].presence)
          allowed = organization && (current_user.admin? ||
            (current_user.organizer_profile&.organization_id == organization.id &&
              OrganizationAuthorization.allowed?(user: current_user, organization: organization,
                permission: :manage_organization)))
        end
        unless allowed
          render json: { error: "You do not have permission to upload an image here" }, status: :forbidden
          return nil
        end

        { event_id: event_id.presence && event.id, organization_id: organization.id }
      end
    end
  end
end
