require "rails_helper"
require "tmpdir"

RSpec.describe "Buyer email language" do
  let(:event) do
    create(:event, :published, title: "Sunset Fiesta", venue_name: "Tumon Bay", timezone: "Pacific/Guam",
      starts_at: Time.utc(2026, 11, 20, 9, 0))
  end
  let(:ticket_type) { create(:ticket_type, event: event, name: "General Admission") }

  before { with_locales_enabled(AppLocale::SUPPORTED, machine_translation: true) }
  after { I18n.reload! }

  def store_korean_copy
    I18n.backend.eager_load! # load the committed files first so these test strings win
    I18n.backend.store_translations(:ko, emails: {
      formats: { event_datetime: "%{year}년 %{month_name} %{day}일 %{meridiem} %{hour}:%{minute}",
                 month_names: (1..12).map { |month| "#{month}월" }, am: "오전", pm: "오후" },
      order_confirmation: { subject: "HåfaPass 티켓 - %{event}", heading: "티켓이 확정되었습니다!",
                            total: "합계: %{amount}" },
      refund: { subject: "환불 완료 - %{event}" }
    })
    event.update_columns(translations: { "title" => AppLocale::TRANSLATION_TARGETS.index_with { |locale| "#{locale}:Sunset Fiesta" }
      .merge("_digest" => Translatable.digest("Sunset Fiesta")) })
  end

  it "writes the order confirmation in the order's language" do
    store_korean_copy
    order = create(:order, event: event, locale: "ko")
    create(:ticket, order: order, event: event, ticket_type: ticket_type)

    payload = EmailService.prepare_delivery_payload(create(:message_delivery, order: order))

    expect(payload.fetch("subject")).to eq("HåfaPass 티켓 - ko:Sunset Fiesta")
    expect(payload.fetch("html")).to include('<html lang="ko">', "티켓이 확정되었습니다!", "합계: US$52.50",
      "2026년 11월 20일 오후 7:00", "ko:Sunset Fiesta")
  end

  it "falls back to English for an order locale that is now disabled" do
    store_korean_copy
    order = create(:order, event: event, locale: "ko")
    with_locales_enabled(%w[en], machine_translation: true)

    payload = EmailService.prepare_delivery_payload(create(:message_delivery, order: order))

    expect(payload.fetch("subject")).to eq("Your HåfaPass Tickets - Sunset Fiesta")
    expect(payload.fetch("html")).to include('<html lang="en">', "Your tickets are confirmed!")
    expect(payload.fetch("html")).not_to include("ko:Sunset Fiesta")
  end

  it "keeps legacy and staff-created orders in English" do
    store_korean_copy
    order = create(:order, event: event)

    payload = EmailService.prepare_delivery_payload(create(:message_delivery, order: order))

    expect(order.locale).to eq("en")
    expect(payload.fetch("subject")).to eq("Your HåfaPass Tickets - Sunset Fiesta")
    expect(payload.fetch("html")).to include("Your tickets are confirmed!", "November 20, 2026 at 7:00 PM", "Total paid: $52.50")
  end

  it "localizes refunds from the order and writes transfers in English for the recipient" do
    store_korean_copy
    order = create(:order, event: event, locale: "ko", status: :refunded, refund_amount_cents: 5250)
    item = create(:refund, order: order, amount_cents: 5250)
    refund = EmailService.prepare_delivery_payload(create(:message_delivery, order: order, template: "refund_notification",
      metadata: { refund_id: item.id }))
    expect(refund.fetch("subject")).to eq("환불 완료 - ko:Sunset Fiesta")

    ticket = create(:ticket, order: create(:order, event: event), event: event, ticket_type: ticket_type)
    transfer = ticket.ticket_transfers.create!(recipient_email: "friend@example.com", locale: "ja",
      expires_at: Time.utc(2026, 11, 19, 9, 0))
    delivery = create(:message_delivery, order: ticket.order, ticket: ticket, template: "ticket_transfer",
      recipient: "friend@example.com", metadata: { ticket_transfer_id: transfer.id })
    payload = EmailService.prepare_delivery_payload(delivery)
    expect(payload.fetch("html")).to include('<html lang="en">', "Sunset Fiesta", "friend@example.com",
      "November 19, 2026 at 7:00 PM ChST")
    expect(payload.fetch("html")).not_to include("ja:Sunset Fiesta")
  end

  it "states the actual cancellation refund amount after an earlier partial refund" do
    event.update!(status: :cancelled)
    order = create(:order, event: event, status: :refunded, refund_amount_cents: 5250)
    refund = create(:refund, order: order, amount_cents: 4000)
    delivery = create(:message_delivery, order: order, template: "refund_notification",
      metadata: { refund_id: refund.id })

    payload = EmailService.prepare_delivery_payload(delivery)

    expect(payload.fetch("subject")).to include("$40.00")
    expect(payload.fetch("html")).to include("refund of $40.00")
    expect(payload.fetch("html")).not_to include("refund of $52.50")
  end

  it "uses the organizer's own ticket names on issued tickets in every language" do
    ticket_type.update_columns(translations: { "name" => AppLocale::TRANSLATION_TARGETS.index_with { |locale| "#{locale}:GA" }
      .merge("_digest" => Translatable.digest("General Admission")) })
    order = create(:order, event: event, locale: "ko")
    create(:ticket, order: order, event: event, ticket_type: ticket_type)

    html = EmailService.prepare_delivery_payload(create(:message_delivery, order: order)).fetch("html")

    expect(html).to include("General Admission")
    expect(html).not_to include("ko:GA")
  end

  it "escapes buyer text inside translated sentences while keeping trusted links" do
    order = create(:order, :with_user, event: event, buyer_name: "<b>Jane</b>")
    html = EmailService.send(:build_order_confirmation_html, order, event, [])

    expect(html).to include("Thank you for your purchase, &lt;b&gt;Jane&lt;/b&gt;.")
    expect(html).to include(%(<a href="#{PublicSiteUrl.frontend}/my-tickets" style="color: #2563eb; text-decoration: none;">My Tickets</a>))
  end

  describe "email copy files" do
    let(:loader) { Rails.root.join("config/locales/emails.rb") }

    it "ignores translated strings that lose placeholders or list entries" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "email_locales"))
        FileUtils.mkdir_p(File.join(root, "locales"))
        File.write(File.join(root, "email_locales/en.yml"),
          { "emails" => { "a" => "Hi %{name}", "b" => "Bye", "months" => %w[Jan Feb] } }.to_yaml)
        File.write(File.join(root, "email_locales/ko.yml"),
          { "emails" => { "a" => "안녕", "b" => "잘가", "months" => %w[1월], "extra" => "x" } }.to_yaml)

        data = eval(File.read(loader), binding, File.join(root, "locales/emails.rb")) # rubocop:disable Security/Eval
        expect(data[:ko]).to eq("emails" => { "b" => "잘가" })
      end
    end

    it "keeps every committed translation compatible with the English copy" do
      english = YAML.safe_load_file(Rails.root.join("config/email_locales/en.yml"))
      flatten = lambda do |value, prefix = nil|
        value.is_a?(Hash) ? value.flat_map { |key, child| flatten.call(child, [prefix, key].compact.join(".")) } : [[prefix, value]]
      end
      english_strings = flatten.call(english).to_h
      Dir[Rails.root.join("config/email_locales/*.yml")].each do |path|
        flatten.call(YAML.safe_load_file(path)).each do |key, value|
          next unless english_strings[key].is_a?(String) && value.is_a?(String)

          expect(value.scan(/%\{\w+\}/).sort).to eq(english_strings[key].scan(/%\{\w+\}/).sort), "#{File.basename(path)} #{key}"
        end
      end
    end
  end
end
