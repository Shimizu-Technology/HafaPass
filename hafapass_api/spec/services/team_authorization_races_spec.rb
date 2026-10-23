require "rails_helper"
require "timeout"

RSpec.describe "Team authorization lock boundaries" do
  self.use_transactional_tests = false

  before do
    @profile = create(:organizer_profile)
    @owner = @profile.user
    @organization = @profile.organization
    @successor = create(:user)
    @successor_membership = create(:organization_membership, organization: @organization, user: @successor, role: :manager)
    @invitee = create(:organization_membership, organization: @organization, user: nil, invited_email: "pending@example.com",
      status: :invited, accepted_at: nil, role: :scanner)
    @event = create(:event, :published, organizer_profile: @profile)
    @organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
  end

  after do
    MessageDelivery.where(event_id: @event.id).delete_all
    CommunicationCampaign.where(event_id: @event.id).delete_all
    # These committed, concurrent fixtures cannot use transaction rollback.
    # Reset the disposable test audit store without bypassing its DELETE guard.
    raise "Isolated test database required" unless Rails.env.test? &&
      ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures")
    OrganizationInvitationDispatch.where(organization_id: @organization.id).delete_all
    EventStaffAssignment.where(organization_id: @organization.id).delete_all
    Event.where(id: @event.id).delete_all
    OrganizationMembership.where(organization_id: @organization.id).delete_all
    OrganizerProfile.where(id: @profile.id).delete_all
    Organization.where(id: @organization.id).delete_all
    User.where(id: [@owner.id, @successor.id]).delete_all
  end

  def wait(queue)
    Timeout.timeout(5) { queue.pop }
  end

  # The worker signals immediately before its contested lock. The first
  # transaction changes authority and commits before the worker can proceed.
  def after_organization_wait(change:, &operation)
    attempting = Queue.new
    result = Queue.new
    allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *args|
      attempting << true if Thread.current[:permission_race]
      method.call(*args)
    end
    worker = nil
    @organization.with_lock do
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '3s'")
          Thread.current[:permission_race] = true
          begin
            result << operation.call
          rescue StandardError => e
            result << e
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end
      wait(attempting)
      change.call
    end
    expect(worker.join(5)).not_to be_nil
    worker.value
    wait(result)
  end

  [:invite, :resend, :revoke, :change_role].each do |operation|
    it "rejects #{operation} when ownership transfers while waiting for the organization" do
      expect(OrganizationAuthorization.allowed?(user: @owner, organization: @organization, permission: :manage_members)).to be(true)
      original = @invitee.attributes
      outcome = after_organization_wait(change: -> {
        OrganizationTeam.transfer_ownership!(organization: @organization, to_membership: @successor_membership, actor: @owner)
      }) do
        case operation
        when :invite
          OrganizationTeam.invite!(organization: @organization, email: "new@example.com", role: :finance, actor: @owner, deliver: false)
        when :resend
          OrganizationTeam.resend!(membership: @invitee, actor: @owner)
        when :revoke
          OrganizationTeam.revoke!(membership: @invitee, actor: @owner)
        when :change_role
          OrganizationTeam.change_role!(membership: @invitee, role: :finance, actor: @owner)
        end
      end
      expect(outcome).to be_a(OrganizationTeam::TeamError)
      expect(outcome.message).to include("permission")
      expect(@invitee.reload.attributes).to eq(original)
      expect(@organization.organization_memberships.where(invited_email: "new@example.com")).not_to exist
      expect(OrganizationInvitationDispatch.where(organization: @organization)).to be_empty
    end
  end

  it "does not queue a campaign after revocation completes during its lock wait" do
    campaign = create(:communication_campaign, event: @event, scheduled_by_user: @successor, status: :scheduled)
    outcome = after_organization_wait(change: -> {
      OrganizationTeam.revoke!(membership: @successor_membership, actor: @owner)
    }) { CommunicationCampaigns::Sender.call(campaign) }
    expect(outcome).to be_a(CommunicationCampaigns::Sender::CampaignError)
    expect(campaign.reload).to be_failed
    expect(campaign.message_deliveries).to be_empty
  end

  it "cancels queued campaign dispatch when sender revocation wins the lock" do
    campaign = create(:communication_campaign, event: @event)
    delivery = create(:message_delivery, event: @event, order: nil, communication_campaign: campaign,
      requested_by: @successor, template: "communication_campaign", recipient: "consented@example.com")
    job = MessageDeliveryJob.new
    allow(EmailService).to receive(:send_delivery_payload)
    outcome = after_organization_wait(change: -> {
      OrganizationTeam.revoke!(membership: @successor_membership, actor: @owner)
    }) { job.send(:dispatch_with_campaign_authorization, delivery, false) { EmailService.send_delivery_payload(delivery) } }
    expect(outcome).to eq(:authorization_cancelled)
    expect(delivery.reload).to be_cancelled
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "keeps revocation waiting until an authorized provider dispatch finishes" do
    campaign = create(:communication_campaign, event: @event)
    delivery = create(:message_delivery, event: @event, order: nil, communication_campaign: campaign,
      requested_by: @successor, template: "communication_campaign", recipient: "consented@example.com")
    in_provider = Queue.new
    release_provider = Queue.new
    attempting = Queue.new
    allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *args|
      attempting << true if Thread.current[:revoker]
      method.call(*args)
    end
    sending = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        MessageDeliveryJob.new.send(:dispatch_with_campaign_authorization, delivery, false) do
          in_provider << true
          wait(release_provider)
          expect(@successor_membership.reload).to be_status_active
          { simulated: true }
        end
      end
    end
    wait(in_provider)
    revoking = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:revoker] = true
        OrganizationTeam.revoke!(membership: @successor_membership, actor: @owner)
      end
    end
    wait(attempting)
    release_provider << true
    [sending, revoking].each { |thread| expect(thread.join(5)).not_to be_nil; thread.value }
    expect(@successor_membership.reload).to be_status_revoked
  end
end
