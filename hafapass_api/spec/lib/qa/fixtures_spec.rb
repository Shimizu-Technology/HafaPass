require "rails_helper"
require Rails.root.join("lib/qa/fixtures")

RSpec.describe Qa::Fixtures do
  around do |example|
    previous = ENV["HAFAPASS_QA_FIXTURES"]
    ENV["HAFAPASS_QA_FIXTURES"] = "1"
    example.run
  ensure
    ENV["HAFAPASS_QA_FIXTURES"] = previous
  end

  before do
    # The safety boundary is tested independently; fixture contents may be
    # exercised by CI's disposable test database regardless of its exact name.
    config = ActiveRecord::Base.connection_db_config
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary",
        config.configuration_hash.merge(database: "hafapass_qa_fixture_spec", host: "localhost"))
    )
    allow(EmailService).to receive(:delivery_provider).and_return("simulated")
    allow(EmailService).to receive(:send_order_confirmation_async)
    expect(StripeService).not_to receive(:create_payment_intent)
  end

  it "creates ordinary isolated roles, older events/orders and a truthful cash fixture without duplication" do
    baseline = { events: Event.count, orders: Order.count, tickets: Ticket.count, admins: User.admin.count }
    fixture = described_class.call(name: "readiness")
    expect(fixture[:roles].keys).to match_array(described_class::ROLES)
    expect(User.admin.count).to eq(baseline[:admins])
    expect(Event.count).to eq(baseline[:events] + 23)
    expect(Order.completed.where(user_id: fixture[:roles]["attendee"][:user_id]).count).to eq(22)
    expect(Ticket.count).to eq(baseline[:tickets] + 22)
    expect(InventoryHold.current.count).to eq(0)
    event = Event.find(fixture[:scanner_event_id])
    expect(event.organization.events.order(created_at: :desc).offset(20).first).to eq(event)
    expect(event.orders.count).to eq(22)
    cash = Order.find_by!(reference: fixture[:cash_order_reference])
    expect(cash.payment_method).to eq("door_cash")
    expect(cash.payments.first).to have_attributes(provider: "door_cash", status: "succeeded")
    expect(OrganizationAuthorization.allowed?(user: User.find(fixture[:roles]["scanner"][:user_id]),
      organization: event.organization, permission: :scan, event: event)).to be(true)
    other_event = Event.find(fixture[:other_event_id])
    expect(other_event.organization_id).not_to eq(event.organization_id)

    expect(described_class.call(name: "readiness")).to eq(fixture)
    expect(Event.count).to eq(baseline[:events] + 23)
    expect(Order.count).to eq(baseline[:orders] + 22)
  end

  it "binds distinct supplied Clerk subjects without granting platform admin access" do
    fixture = described_class.call(name: "bound", identities: { organizer: "user_actual_test_organizer" })
    organizer = User.find(fixture[:roles]["organizer"][:user_id])
    expect(organizer).to have_attributes(clerk_id: "user_actual_test_organizer", role: "organizer")
    expect(organizer.organization_memberships.first).to have_attributes(role: "owner", status: "active")
    expect(User.admin.count).to eq(0)
  end

  it "refuses production before creating any rows" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect { described_class.call }.to raise_error(described_class::UnsafeEnvironment)
    expect(User.count).to eq(0)
  end

  it "refuses a shared database even with the opt-in" do
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary",
        adapter: "postgresql", database: "hafapass_api_development", host: "localhost")
    )
    expect { described_class.call }.to raise_error(described_class::UnsafeEnvironment)
    expect(User.count).to eq(0)
  end

  it "requires the explicit fixture opt-in" do
    ENV.delete("HAFAPASS_QA_FIXTURES")
    expect { described_class.call }.to raise_error(described_class::UnsafeEnvironment)
    expect(User.count).to eq(0)
  end

  it "refuses real transport or a non-simulated payment setting" do
    allow(EmailService).to receive(:delivery_provider).and_return("resend")
    expect { described_class.call }.to raise_error(described_class::UnsafeEnvironment)
    allow(EmailService).to receive(:delivery_provider).and_return("simulated")
    SiteSetting.instance.update!(payment_mode: "test")
    expect { described_class.call }.to raise_error(described_class::UnsafeEnvironment)
    expect(User.count).to eq(0)
  end

  it "rejects using the same provider identity for two roles" do
    expect { described_class.call(identities: { organizer: "same_subject", attendee: "same_subject" }) }
      .to raise_error(ArgumentError, /distinct/)
    expect(User.count).to eq(0)
  end

  it "rolls back when a bound identity would grant an administrator bypass" do
    admin = create(:user, :admin)
    expect { described_class.call(identities: { organizer: admin.clerk_id }) }
      .to raise_error(described_class::UnsafeEnvironment, /different platform role/)
    expect(Organization.where("name LIKE ?", "QA readiness %").count).to eq(0)
    expect(admin.reload).to be_admin
  end
end
