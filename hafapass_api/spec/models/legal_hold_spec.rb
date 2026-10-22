require "rails_helper"

RSpec.describe LegalHold do
  let(:admin) { create(:user, :admin) }
  let(:order) { create(:order, :with_user) }

  %w[organization event order user buyer_email].each do |scope|
    it "blocks an order through a #{scope} hold and audits release" do
      value = case scope
      when "organization" then order.event.organization_id.to_s
      when "event" then order.event_id.to_s
      when "order" then order.id.to_s
      when "user" then order.user_id.to_s
      else order.buyer_email
      end
      hold = described_class.place!(scope_type: scope, scope_value: value,
        reason: "Preserve records for a live legal matter", actor: admin)
      expect(described_class.for_order?(order)).to be(true)
      hold.release!(actor: admin)
      expect(described_class.for_order?(order)).to be(false)
      expect(AuditLog.where(auditable: hold).pluck(:action)).to contain_exactly("legal_hold.placed", "legal_hold.released")
    end
  end
end
