# frozen_string_literal: true

require "csv"

# Organization context is resolved server-side. An admin must explicitly choose platform scope.
class Api::V1::AudienceMailingsController < Api::V1::Organizer::BaseController
  skip_before_action :require_current_organization
  before_action :authorize_scope
  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end
  rescue_from ArgumentError do
    render json: { error: "Invalid date" }, status: :unprocessable_entity
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { error: error.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def audience
    if @organization.nil?
      scope = PlatformSubscriber.order(created_at: :desc)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where("interests @> ?::jsonb", [params[:interest]].to_json) if params[:interest].present?
      scope = scope.where("created_at >= ?", Time.zone.parse(params[:since])) if params[:since].present?
      scope = scope.where("email ILIKE ?", "%#{PlatformSubscriber.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
      if params[:format] == "csv"
        AuditLogger.record!(action: "email.audience_exported", auditable: current_user, metadata: { scope: "platform", count: scope.count })
        return send_data(csv(scope.pluck(:email, :status, :source, :created_at)), filename: "platform-subscribers.csv")
      end
      rows = scope.limit(200).map { |row| row.as_json.merge(consents: EmailConsent.where(email: row.email).order(created_at: :desc).limit(30).as_json) }
      render json: { subscribers: rows, count: scope.count, counts: PlatformSubscriber.group(:status).count,
        growth: PlatformSubscriber.group("DATE(created_at)").count, eligible: draft.audience_emails.size }
    else
      emails = draft.audience_emails.grep(/#{Regexp.escape(params[:q].to_s)}/i)
      if params[:format] == "csv"
        AuditLogger.record!(action: "email.audience_exported", auditable: @organization, metadata: { scope: params[:audience], count: emails.size })
        return send_data(csv(emails.map { |email| [email] }), filename: "organizer-audience.csv")
      end
      render json: { subscribers: emails.first(200).map { |email| { email: email } }, count: emails.size, eligible: emails.size }
    end
  end

  def suppress
    return head :forbidden if @organization

    subscriber = PlatformSubscriber.find(params[:id])
    subscriber.with_lock do
      subscriber.update!(status: "unsubscribed", confirmation_nonce: SecureRandom.hex(24))
      EmailConsent.record!(email: subscriber.email, scope: "platform", action: "admin_unsubscribed", source: "admin")
      AuditLogger.record!(action: "email.subscriber_suppressed", auditable: subscriber)
    end
    head :no_content
  end

  def index
    render json: { mailings: mailings.order(created_at: :desc).limit(100).map { |mailing| serialize(mailing) } }
  end

  def create
    mailing = draft
    mailing.save!
    render json: serialize(mailing), status: :created
  end

  def preview
    mailing = draft
    return render json: { error: "Certified postal address required" }, status: :unprocessable_entity if mailing.address.blank?
    return render json: { error: mailing.errors.full_messages.join(", ") }, status: :unprocessable_entity unless mailing.valid?

    delivery = mailing.delivery(current_user.email)
    render json: { html: EmailService.prepare_delivery_payload(delivery).fetch("html"), eligible: mailing.audience_emails.size }
  end

  def test_send
    mailing = mailings.find(params[:id])
    return head :forbidden unless ClerkIdentity.email_matches?(user: current_user, email: current_user.email)
    return render json: { error: "Certified postal address required" }, status: :unprocessable_entity if mailing.address.blank?

    delivery = mailing.delivery(current_user.email, test: true)
    delivery.requested_by = current_user
    delivery.save!
    MessageDeliveryJob.perform_later(delivery.id)
    render json: { queued: true }
  end

  def send_now
    mailing = mailings.find(params[:id])
    mailing.with_lock do
      return head :conflict unless mailing.status == "draft"
      return render json: { error: "Certified postal address required" }, status: :unprocessable_entity if mailing.address.blank?

      time = params[:scheduled_at].present? ? Time.zone.parse(params[:scheduled_at]) : Time.current
      mailing.update!(created_by: current_user, status: "scheduled", scheduled_at: time)
      ActiveRecord.after_all_transactions_commit do
        if time <= Time.current
          AudienceMailingJob.perform_later(mailing.id)
        else
          AudienceMailingJob.set(wait_until: time).perform_later(mailing.id)
        end
      end
    end
    render json: serialize(mailing)
  end

  private

  def authorize_scope
    if params[:scope] == "platform"
      return head :forbidden unless current_user.admin?
      @organization = nil
    else
      @organization = current_organization
      return head :forbidden unless @organization

      authorize_organization!(:manage_marketing)
    end
  end

  def mailings
    AudienceMailing.where(organization: @organization)
  end

  def draft
    AudienceMailing.new(organization: @organization, created_by: current_user,
      subject: params[:subject].presence || "Event alerts", body: params[:body].presence || "Upcoming events on Guam",
      audience: @organization ? params[:audience].presence || "buyers" : "platform")
  end

  def serialize(mailing)
    mailing.as_json.merge("counts" => mailing.message_deliveries.where(template: "audience_mailing").group(:status).count,
      "unsubscribed" => mailing.message_deliveries.where(template: "audience_mailing").pluck(:recipient).count { |email|
        EmailPreference.blocked?(email) || (mailing.organization ?
          MarketingUnsubscribe.exists?(organization: mailing.organization, email: email) :
          PlatformSubscriber.exists?(email: email, status: "unsubscribed"))
      })
  end

  def csv(rows)
    CSV.generate { |out| rows.each { |row| out << row.map { |value| value.to_s.match?(/\A[\s]*[=+@-]/) ? "'#{value}" : value } } }
  end
end
