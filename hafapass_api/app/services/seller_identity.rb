# frozen_string_literal: true

# Who sells what on an order. The organizer is the seller of the event ticket;
# the platform (operated by Shimizu Technology) is the ticketing service that
# sells as the organizer's limited agent and collects the service fee. Receipts,
# tickets and emails show both so the agency arrangement is visible to buyers.
class SellerIdentity
  OPERATOR_NAME = "Shimizu Technology"

  Identity = Data.define(:seller_name, :ticketing_service, :operator_name) do
    def line
      "Sold by #{seller_name} · Tickets by #{ticketing_service}"
    end

    def as_json(*)
      { seller_name: seller_name, ticketing_service: ticketing_service, operator_name: operator_name, line: line }
    end
  end

  def self.for_event(event, platform_name: nil)
    seller = event.organizer_profile&.business_name.presence || event.organization&.name.presence || "the event organizer"
    Identity.new(seller_name: seller, ticketing_service: platform_name.presence || self.platform_name,
      operator_name: OPERATOR_NAME)
  end

  def self.platform_name
    SiteSetting.instance.platform_name.presence || "HåfaPass"
  end
end
