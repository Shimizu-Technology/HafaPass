# frozen_string_literal: true

require "csv"

# Organization context is resolved server-side. An admin must explicitly choose platform scope.
class Api::V1::AudienceMailingsController < Api::V1::Organizer::BaseController
  skip_before_action :require_current_organization
  before_action :authorize_scope
  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { error: error.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def audience
    return render json: { error: "Invalid date" }, status: :unprocessable_entity unless valid_filters?

    if @organization.nil?
      scope = PlatformSubscriber.order(created_at: :desc)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where("interests @> ?::jsonb", [params[:interest]].to_json) if params[:interest].present?
      scope = scope.where("created_at >= ?", Date.iso8601(params[:since])) if params[:since].present?
      scope = scope.where("email ILIKE ?", "%#{PlatformSubscriber.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
      if params[:format] == "csv"
        AuditLogger.record!(action: "email.audience_exported", auditable: current_user, metadata: { scope: "platform", count: scope.count })
        return send_data(csv(scope.pluck(:email, :status, :source, :created_at)), filename: "platform-subscribers.csv")
      end
      page = scope.limit(200).to_a
      consents = EmailConsent.where(email: page.map(&:email)).order(created_at: :desc).group_by(&:email)
      rows = page.map { |row| row.as_json.merge(consents: consents.fetch(row.email, []).first(30).as_json) }
      render json: { subscribers: rows, count: scope.count, counts: PlatformSubscriber.group(:status).count,
        growth: PlatformSubscriber.where("created_at >= ?", 90.days.ago).group("DATE(created_at)").count, eligible: draft.audience_emails.size }
    else
      emails = draft.audience_emails
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
    EmailPreferences.with_platform_locks(subscriber.email) do |_preference, locked_subscriber|
      subscriber = locked_subscriber
      subscriber.update!(status: %w[bounced complained].include?(subscriber.status) ? subscriber.status : "unsubscribed", confirmation_nonce: SecureRandom.hex(24))
      EmailConsent.record!(email: subscriber.email, scope: "platform", action: "admin_unsubscribed", source: "admin")
      AuditLogger.record!(action: "email.subscriber_suppressed", auditable: subscriber)
    end
    head :no_content
  end

  def index
    rows = mailings.includes(:organization).order(created_at: :desc).limit(100).to_a
    deliveries = MessageDelivery.where(audience_mailing_id: rows.map(&:id), template: "audience_mailing")
    @history_counts = deliveries.group(:audience_mailing_id, :status).count.group_by { |(key, _)| key.first }
    @history_unsubscribed = deliveries.where("recipient IN (SELECT email FROM email_preferences WHERE all_unsubscribed = TRUE) OR (EXISTS (SELECT 1 FROM audience_mailings am WHERE am.id = message_deliveries.audience_mailing_id AND am.organization_id IS NULL) AND recipient IN (SELECT email FROM platform_subscribers WHERE status = 'unsubscribed')) OR EXISTS (SELECT 1 FROM marketing_unsubscribes mu JOIN audience_mailings am ON am.organization_id = mu.organization_id WHERE am.id = message_deliveries.audience_mailing_id AND mu.email = message_deliveries.recipient)").group(:audience_mailing_id).count
    render json: { mailings: rows.map { |mailing| serialize(mailing) } }
  end

  def create
    return render json: { error: "Invalid date" }, status: :unprocessable_entity unless valid_filters?

    mailing = draft
    mailing.save!
    render json: serialize(mailing), status: :created
  end

  def preview
    return render json: { error: "Invalid date" }, status: :unprocessable_entity unless valid_filters?

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

      begin
        time = params[:scheduled_at].present? ? Time.iso8601(params[:scheduled_at]) : Time.current
        raise ArgumentError if time < 1.minute.ago
      rescue ArgumentError, TypeError
        return render json: { error: "Invalid schedule" }, status: :unprocessable_entity
      end
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

  def cancel
    mailing = mailings.find(params[:id])
    mailing.with_lock do
      return head :conflict unless mailing.status == "scheduled"

      mailing.update!(status: "cancelled")
    end
    render json: serialize(mailing)
  end

  private

  def valid_filters?
    Date.iso8601(params[:since]) if params[:since].present?
    true
  rescue ArgumentError, TypeError
    false
  end

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
      filters: params.permit(:q, :status, :source, :interest, :since).to_h,
      audience: @organization ? params[:audience].presence || "buyers" : "platform")
  end

  def serialize(mailing)
    if @history_counts
      counts = @history_counts.fetch(mailing.id, []).to_h { |(key, count)| [key.last, count] }
      return mailing.as_json(except: :recipient_emails).merge("counts" => counts, "unsubscribed" => @history_unsubscribed.fetch(mailing.id, 0))
    end
    mailing.as_json(except: :recipient_emails).merge("counts" => mailing.message_deliveries.where(template: "audience_mailing").group(:status).count,
      "unsubscribed" => mailing.message_deliveries.where(template: "audience_mailing")
        .where("recipient IN (SELECT email FROM email_preferences WHERE all_unsubscribed = TRUE) OR (EXISTS (SELECT 1 FROM audience_mailings am WHERE am.id = message_deliveries.audience_mailing_id AND am.organization_id IS NULL) AND recipient IN (SELECT email FROM platform_subscribers WHERE status = 'unsubscribed')) OR recipient IN (SELECT email FROM marketing_unsubscribes WHERE organization_id = ?)", mailing.organization_id).count)
  end

  def csv(rows)
    CSV.generate { |out| rows.each { |row| out << row.map { |value| value.to_s.match?(/\A[\s]*[=+@-]/) ? "'#{value}" : value } } }
  end
end
