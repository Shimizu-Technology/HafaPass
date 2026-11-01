module Api
  module V1
    class HealthController < ApplicationController
      skip_before_action :authenticate_user!

      def show
        render json: { status: "ok", timestamp: Time.current.iso8601,
          revision: ApplicationRevision.configured? ? ApplicationRevision.current.downcase : nil }
      end

      # Anyone (and any uptime monitor) gets the same 200/503 verdict. The
      # dependency detail needs X-Readiness-Token matching READINESS_TOKEN;
      # with the variable unset, detail is simply unavailable.
      def readiness
        result = SystemReadiness.call
        body = readiness_detail? ? result.merge(request_ip_source: Operations::ClientIpSource.describe(request)) :
          result.slice(:status, :timestamp)
        render json: body, status: result[:status] == "ready" ? :ok : :service_unavailable
      end

      private

      def readiness_detail?
        expected = ENV["READINESS_TOKEN"].to_s
        supplied = request.headers["X-Readiness-Token"].to_s
        expected.present? && supplied.present? && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
      end
    end
  end
end
