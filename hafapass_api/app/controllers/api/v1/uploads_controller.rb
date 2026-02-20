module Api
  module V1
    class UploadsController < ApplicationController
      # POST /api/v1/uploads/presign
      def presign
        filename = params[:filename]
        content_type = params[:content_type]

        if filename.blank? || content_type.blank?
          return render json: { error: "filename and content_type are required" }, status: :unprocessable_entity
        end

        unless content_type.start_with?("image/")
          return render json: { error: "Only image uploads are allowed" }, status: :unprocessable_entity
        end

        result = S3Service.generate_presigned_post(
          filename,
          content_type,
          event_id: params[:event_id]
        )

        if result
          render json: result
        else
          render json: { error: "Failed to generate upload URL" }, status: :internal_server_error
        end
      end
    end
  end
end
