require "rails_helper"

RSpec.describe "Legacy email job recovery" do
  before do
    allow(EmailService).to receive(:configured?).and_return(true)
    allow(Resend).to receive(:api_key).and_return("synthetic-original-key")
    allow(Resend::Emails).to receive(:send).and_return({ id: "synthetic-provider-id" })
  end

  [SendTicketEmailJob, SendOrderConfirmationJob].each do |job_class|
    context job_class.name do
      let(:subject) { job_class == SendTicketEmailJob ? create(:ticket) : create(:order) }
      let(:attributes) do
        job_class == SendTicketEmailJob ? { ticket: subject, order: subject.order, template: "ticket_delivery" } :
          { order: subject, template: "order_confirmation" }
      end

      it "fails closed when an old queued job has no durable delivery" do
        id = subject.id
        expect { job_class.new.perform(id) }.to raise_error(MessageWirePayload::Unavailable)
        expect(Resend::Emails).not_to have_received(:send)
        expect(MessageDelivery.count).to eq(0)
      end

      it "does not regenerate an attempted legacy request whose wire body is missing" do
        payload = { "to" => "buyer@synthetic.invalid", "html" => "Frozen fixture" }
        delivery = create(:message_delivery, **attributes, attempts: 1, status: :failed, recipient: payload.fetch("to"),
          provider_outcome_unknown: true, provider_attempted_at: 1.hour.ago, outbound_payload: payload,
          transport_context_digest: EmailService.transport_context_digest)
        allow(EmailService).to receive(:prepare_delivery_payload)

        expect { job_class.new.perform(subject.id, delivery.id) }.to raise_error(MessageWirePayload::Unavailable)

        expect(EmailService).not_to have_received(:prepare_delivery_payload)
        expect(Resend::Emails).not_to have_received(:send)
        expect(delivery.reload).to have_attributes(attempts: 1, provider_id: nil, outbound_payload: payload,
          provider_outcome_unknown: true, outbound_wire_body: nil)
        expect(MessageDelivery.count).to eq(1)
      end

      it "delegates a fresh matching journal to the canonical durable send lifecycle" do
        delivery = create(:message_delivery, **attributes)

        job_class.new.perform(subject.id, delivery.id)

        expect(delivery.reload).to have_attributes(status: "sent", attempts: 1, provider_id: "synthetic-provider-id",
          provider_outcome_unknown: false)
        expect(delivery.outbound_wire_body).to be_present
        expect(delivery.wire_body_digest).to eq(Digest::SHA256.hexdigest(delivery.outbound_wire_body))
        expect(Resend::Emails).to have_received(:send) do |params, options:|
          expect(params.to_json).to eq(delivery.outbound_wire_body)
          expect(options).to eq(idempotency_key: delivery.idempotency_key)
        end
        expect(MessageDelivery.count).to eq(1)
      end
    end
  end
end
