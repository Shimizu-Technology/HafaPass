export const event = { id: 601, slug: 'community-night', title: 'Guam community night', status: 'published', starts_at: '2099-11-20T08:00:00Z', ends_at: '2099-11-20T11:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Community Hall', venue_city: 'Hagåtña', purchasable: true, category: 'concert', description: 'An evening of food and live music with our neighbors.', organizer: { id: 1, name: 'Island events', business_name: 'Island events', slug: 'island-events' }, ticket_types: [{ id: 10, name: 'General admission', price_cents: 2500, current_price_cents: 2500, all_in_price_cents: 2725, service_fee_cents: 225, quantity_remaining: 20, on_sale: true }] }
export const events = [event, { ...event, id: 602, slug: 'food-fair', title: 'An evening of food, music and stories with our neighbors in Mongmong-Toto-Maite', category: 'festival', venue_name: 'Mongmong-Toto-Maite Community Center', ticket_types: [{ id: 11, name: 'Entry', price_cents: 0, quantity_remaining: 20, on_sale: true }] }, { ...event, id: 603, slug: 'workshop', title: 'Weekend printmaking workshop', category: 'workshop', venue_name: '' }]
export const config = { payment_mode: 'simulate', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', support_email: 'buyer-pages-qa@example.test', launch_capabilities: { ticket_transfers: true } }
export const tickets = [
  { id: 701, order_id: 601, status: 'issued', admission_allowed: true, display_credential: 'display-qa', scan_credential: 'synthetic-buyer-pages-qa', wallet_availability: {}, attendee_name: 'Jo', event, ticket_type: { name: 'General admission' } },
  { id: 702, order_id: 601, status: 'checked_in', admission_allowed: false, display_credential: 'display-used', event, ticket_type: { name: 'General admission' } },
]
export const collection = { id: 1, slug: 'this-weekend', title: 'This weekend', description: 'Food, music and time with friends.', events }
export const order = { id: 601, reference: 'HP-QA601', status: 'completed', buyer_status: 'completed', payment_environment: 'simulate', subtotal_cents: 2500, service_fee_cents: 225, total_cents: 2725, completed_at: '2026-10-28T01:00:00Z', created_at: '2026-10-28T01:00:00Z', event, order_items: [{ id: 1, name: 'General admission', quantity: 1, unit_price_cents: 2500, total_cents: 2500 }], tickets: [tickets[0]], email_delivery: { status: 'delivered' } }
export async function prepare(page, state = {}) {
  const json = (route, data) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(data) })
  await page.addInitScript(() => {
    sessionStorage.setItem('hafapass:order-access:601', 'synthetic-guest')
    window.qaCLS = 0
    window.qaShifts = []
    window.qaCLSAvailable = PerformanceObserver.supportedEntryTypes.includes('layout-shift')
    if (window.qaCLSAvailable) new PerformanceObserver(list => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) { window.qaCLS += entry.value; window.qaShifts.push({ value: entry.value, sources: entry.sources?.map(source => ({ node: source.node?.outerHTML?.slice(0, 160), before: source.previousRect.toJSON(), after: source.currentRect.toJSON() })) }) } }).observe({ type: 'layout-shift', buffered: true })
  })
  await page.route('**/api/v1/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname.replace('/api/v1', '')
    const catalog = state.empty ? [] : state.events || events
    const data = path === '/health' ? { status: 'ok' }
      : path === '/config' ? config
      : path === '/event_categories' ? { categories: [] }
      : path === '/events' ? { events: state.noMatch || url.searchParams.has('q') ? [] : catalog, meta: { current_page: 1, total_pages: 1, total_count: state.noMatch ? 0 : catalog.length } }
      : path === '/events/community-night' ? event
      : path.startsWith('/tickets/') ? tickets[0]
      : path === '/orders/601' ? order
      : path === '/me/tickets' ? { tickets: state.empty ? [] : state.tickets || tickets, meta: {} }
      : path === '/me/orders/recover_guest' ? { recovered_orders_count: 0 }
      : path === '/me/orders' ? { orders: state.empty ? [] : [order], meta: {} }
      : path === '/marketplace_collections' ? { collections: state.empty ? [] : [collection] }
      : path.startsWith('/marketplace_collections/') ? { ...collection, meta: { total_count: 3, current_page: 1, total_pages: 1 } }
      : path === '/me/event_favorites' ? { events: catalog }
      : path === '/me/organizer_follows' ? { organizers: state.empty ? [] : [{ id: 1, name: 'Island events', slug: 'island-events' }] }
      : path === '/me/event_reminders' ? { reminders: state.empty ? [] : [{ id: 1, status: 'pending', event, remind_at: '2099-11-19T08:00:00Z' }] }
      : {}
    return json(route, data)
  })
}
