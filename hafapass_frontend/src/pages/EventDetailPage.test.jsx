import { act, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import EventDetailPage from './EventDetailPage'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, userId: null }) }))
vi.mock('framer-motion', async original => ({ ...(await original()), useReducedMotion: () => true }))
const seo = vi.hoisted(() => ({ props: null }))
vi.mock('../components/SEO', () => ({ default: props => { seo.props = props; return null } }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => children }))
vi.mock('../utils/marketplaceAttribution', () => ({ captureQueryAttribution: vi.fn(), trackFunnel: vi.fn() }))

const baseEvent = {
  id: 7, slug: 'reef-night', title: 'Reef Night', description: 'Snorkel social', status: 'published', purchasable: true,
  category: 'nightlife', category_label: 'Nightlife', timezone: 'Pacific/Guam', starts_at: '2099-10-20T08:00:00Z',
  venue_name: 'Tumon Bay Pavilion', venue_address: '123 Pale San Vitores Rd, Tumon', attendee_count: 0, attendees_preview: [],
  ticket_types: [
    { id: 1, name: 'VIP', price_cents: 4500, on_sale: true, quantity_remaining: 5 },
    { id: 2, name: 'General', price_cents: 1500, on_sale: true, quantity_remaining: 20 },
  ],
}

// Lets each test decide which observed elements (hero button, ticket panel, page end) are in view.
let observers = []
class FakeIntersectionObserver {
  constructor(callback) { this.callback = callback; this.elements = []; observers.push(this) }
  observe(element) { this.elements.push(element) }
  disconnect() {}
}
const reportAllOutOfView = (top = 900) => act(() => observers.forEach(observer =>
  observer.callback(observer.elements.map(target => ({ target, isIntersecting: false, boundingClientRect: { top } })))))

function mount(event) {
  apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { payment_mode: 'simulate' } : event }))
  return render(<MemoryRouter initialEntries={[`/events/${event.slug}`]}><Routes>
    <Route path="/events/:slug" element={<EventDetailPage />} />
  </Routes></MemoryRouter>)
}

it('loads fragment previews with a header and no query token', async () => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { ...baseEvent, private_preview: true, purchasable: false } })
  render(<MemoryRouter initialEntries={['/events/reef-night/preview#t=private-secret']}><Routes>
    <Route path="/events/:slug/preview" element={<EventDetailPage />} />
  </Routes></MemoryRouter>)
  await screen.findByRole('heading', { name: 'Reef Night' })
  expect(apiClient.get).toHaveBeenCalledWith('/events/reef-night/private_preview', {
    headers: { 'X-Preview-Token': 'private-secret' },
  })
  expect(seo.props).toMatchObject({ noIndex: true, noSocial: true })
})

it('hides the waitlist in a sold-out private preview', async () => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { ...baseEvent, private_preview: true, purchasable: false,
    ticket_types: baseEvent.ticket_types.map(ticket => ({ ...ticket, quantity_remaining: 0, quantity_available: 10, quantity_sold: 10 })) } })
  render(<MemoryRouter initialEntries={['/events/reef-night/preview#t=private-secret']}><Routes>
    <Route path="/events/:slug/preview" element={<EventDetailPage />} />
  </Routes></MemoryRouter>)
  await screen.findByRole('heading', { name: 'Reef Night' })
  expect(screen.queryByText('Join the Waitlist')).not.toBeInTheDocument()
  expect(screen.queryByText('Already on the waitlist?')).not.toBeInTheDocument()
})

it('replaces a legacy query preview with a fragment before requesting event data', async () => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { ...baseEvent, private_preview: true, purchasable: false } })
  render(<MemoryRouter initialEntries={['/events/reef-night?preview_token=old-secret']}><Routes>
    <Route path="/events/:slug" element={<EventDetailPage />} />
    <Route path="/events/:slug/preview" element={<><EventDetailPage /><span data-testid="preview-route">Preview route</span></>} />
  </Routes></MemoryRouter>)
  await screen.findByTestId('preview-route')
  await screen.findByRole('heading', { name: 'Reef Night' })
  expect(apiClient.get).toHaveBeenCalledWith('/events/reef-night/private_preview', {
    headers: { 'X-Preview-Token': 'old-secret' },
  })
  expect(apiClient.get.mock.calls.some(([url]) => url.includes('old-secret'))).toBe(false)
})

describe('EventDetailPage all-in pricing and seller identity', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    observers = []
    vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('advertises all-in prices in the buy bar and structured data and names the seller', async () => {
    mount({
      ...baseEvent,
      service_fee_includes_processing: true,
      seller: { seller_name: 'Island Nights', ticketing_service: 'HåfaPass', line: 'Sold by Island Nights · Tickets by HåfaPass' },
      ticket_types: [
        { id: 1, name: 'VIP', price_cents: 4500, current_price_cents: 4500, all_in_price_cents: 4825, service_fee_cents: 325, on_sale: true, quantity_remaining: 5 },
        { id: 2, name: 'General', price_cents: 1500, current_price_cents: 1500, all_in_price_cents: 1675, service_fee_cents: 175, on_sale: true, quantity_remaining: 20 },
      ],
    })
    await screen.findByRole('heading', { name: 'Reef Night' })
    await waitFor(() => {
      reportAllOutOfView()
      expect(screen.getByTestId('mobile-buy-bar')).toHaveAttribute('data-visible', 'true')
    })
    expect(within(screen.getByTestId('mobile-buy-bar')).getByText('From $16.75')).toBeInTheDocument()
    expect(screen.getByText('$48.25')).toBeInTheDocument()
    expect(screen.getByTestId('seller-line')).toHaveTextContent('Tickets by')
    expect(screen.getByTestId('all-in-note')).toHaveTextContent('Prices include all mandatory fees.')
    expect(seo.props.jsonLd.offers).toMatchObject({ lowPrice: '16.75', highPrice: '48.25', priceCurrency: 'USD' })
    expect(seo.props.description).toContain('From $16.75. Prices include all mandatory fees.')
  })
})

describe('EventDetailPage buyer polish', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    observers = []
    vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('explains a withdrawn offer link and does not offer its claim button', async () => {
    apiClient.get.mockImplementation(url => url.startsWith('/waitlist_offers/')
      ? Promise.reject({ response: { status: 410, data: { code: 'offer_withdrawn', event_slug: 'reef-night' } } })
      : Promise.resolve({ data: baseEvent }))
    render(<MemoryRouter initialEntries={['/events/reef-night?waitlist_offer=signed-offer']}><Routes>
      <Route path="/events/:slug" element={<EventDetailPage />} />
    </Routes></MemoryRouter>)

    expect(await screen.findByText("This ticket offer was withdrawn — you're still on the waitlist and we'll email you if tickets become available")).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Claim waitlist offer' })).not.toBeInTheDocument()
  })

  it('keeps the back link on its own row above the category label', async () => {
    mount(baseEvent)
    const back = await screen.findByRole('link', { name: 'All Events' })
    expect(back).toHaveClass('flex', 'mb-6')
    expect(screen.getByText('Nightlife')).toHaveClass('block')
  })

  it('shows the phone buy bar with the lowest price once the ticket panel scrolls away', async () => {
    mount(baseEvent)
    await screen.findByRole('heading', { name: 'Reef Night' })
    const bar = screen.getByTestId('mobile-buy-bar')
    expect(bar).toHaveAttribute('data-visible', 'false')
    expect(bar).toHaveAttribute('inert')
    expect(bar).toHaveClass('lg:hidden')
    // Late page data can re-render the bar on a slow runner; report again and
    // re-query until the settled bar reacts, instead of holding a stale node.
    await waitFor(() => {
      reportAllOutOfView()
      expect(screen.getByTestId('mobile-buy-bar')).toHaveAttribute('data-visible', 'true')
    })
    const shownBar = screen.getByTestId('mobile-buy-bar')
    expect(shownBar).not.toHaveAttribute('inert')
    expect(within(shownBar).getByText('From $15.00')).toBeInTheDocument()
    const link = within(shownBar).getByRole('link', { name: /Get tickets/ })
    expect(link).toHaveAttribute('href', '#tickets')
    const panel = document.getElementById('tickets')
    panel.scrollIntoView = vi.fn()
    link.click()
    expect(panel.scrollIntoView).toHaveBeenCalled()
    expect(panel).toHaveFocus()
    // Programmatic focus after keyboard activation keeps a visible indicator.
    expect(panel).not.toHaveClass('focus-visible:outline-none')
    expect(panel).toHaveClass('focus-visible:outline', 'focus-visible:outline-2', 'focus-visible:outline-focus')
  })

  it('keeps the buy bar hidden while only the ticket panel is in view', async () => {
    mount(baseEvent)
    await screen.findByRole('heading', { name: 'Reef Night' })
    const panel = document.getElementById('tickets')
    act(() => observers.forEach(observer => observer.callback(observer.elements.map(target =>
      ({ target, isIntersecting: target === panel, boundingClientRect: { top: target === panel ? 100 : 900 } })))))
    expect(screen.getByTestId('mobile-buy-bar')).toHaveAttribute('data-visible', 'false')
  })

  it('does not render the buy bar when no ticket type is on sale and seating is not assigned', async () => {
    mount({ ...baseEvent, purchasable: true, assigned_seating: false,
      ticket_types: baseEvent.ticket_types.map(ticket => ({ ...ticket, on_sale: false })) })
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(screen.queryByTestId('mobile-buy-bar')).not.toBeInTheDocument()
  })

  it('hides the buy bar after the visitor scrolls past the end of the event content', async () => {
    mount(baseEvent)
    await screen.findByRole('heading', { name: 'Reef Night' })
    reportAllOutOfView(-200)
    expect(screen.getByTestId('mobile-buy-bar')).toHaveAttribute('data-visible', 'false')
  })

  it('labels free events and hides the buy bar while tickets are not on sale', async () => {
    const free = { ...baseEvent, ticket_types: [{ id: 3, name: 'Free entry', price_cents: 0, on_sale: true, quantity_remaining: 3 }] }
    const { unmount } = mount(free)
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(within(screen.getByTestId('mobile-buy-bar')).getByText('Free')).toBeInTheDocument()
    unmount()

    mount({ ...baseEvent, purchasable: false })
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(screen.queryByTestId('mobile-buy-bar')).not.toBeInTheDocument()
  })

  it('shows the venue as an address row with a Directions link instead of a map placeholder', async () => {
    mount(baseEvent)
    const location = await screen.findByRole('region', { name: 'Location' })
    expect(within(location).getByText('Tumon Bay Pavilion')).toBeInTheDocument()
    expect(within(location).getByText('123 Pale San Vitores Rd, Tumon')).toBeInTheDocument()
    const directions = within(location).getByRole('link', { name: /Directions/ })
    expect(directions).toHaveAttribute('href', `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent('Tumon Bay Pavilion, 123 Pale San Vitores Rd, Tumon')}`)
    expect(directions).toHaveAttribute('target', '_blank')
  })

  it('links the venue name to its venue page when the venue has one', async () => {
    mount({ ...baseEvent, venue: { slug: 'tumon-bay-pavilion' } })
    const location = await screen.findByRole('region', { name: 'Location' })
    expect(within(location).getByRole('link', { name: 'Tumon Bay Pavilion' })).toHaveAttribute('href', '/venues/tumon-bay-pavilion')
    expect(within(location).getByRole('link', { name: /Directions/ })).toHaveAttribute('href', expect.stringContaining('google.com/maps'))
  })
  it('renders design around the fixed ticket box and includes lineup in structured data', async () => {
    const cover = 'https://storage.invalid/uploads/cover.webp'
    mount({ ...baseEvent, image_asset_host: 'storage.invalid', cover_image_url: cover, description: 'Plain first line\nPlain second line',
      organizer: { business_name: 'Island Studio', slug: 'island-studio', logo_url: 'https://storage.invalid/uploads/logo.webp' },
      seller: { seller_name: 'Island Studio', ticketing_service: 'HåfaPass' },
      page_customization: { accent: '#123456', focal_point: { x: 25, y: 70 },
        sections: [{ type: 'lineup', enabled: true, items: [{ name: 'Mia Cruz', role: 'Singer' }] },
          { type: 'faq', enabled: true, items: [{ question: 'When?', answer: 'Tonight' }] }] } })
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(document.querySelector(`img[src="${cover}"]`)).toHaveStyle({ objectPosition: '25% 70%' })
    expect(screen.getByText(/Plain first line/)).toHaveClass('whitespace-pre-wrap')
    expect(screen.getByRole('heading', { name: 'Lineup' })).toBeInTheDocument()
    expect(screen.getByText('Mia Cruz')).toBeInTheDocument()
    expect(screen.getByText('When?')).toBeInTheDocument()
    expect(screen.getByTestId('seller-line')).toBeInTheDocument()
    expect(document.querySelector('img[src="https://storage.invalid/uploads/logo.webp"]')).toBeInTheDocument()
    expect(seo.props.jsonLd.performer).toEqual([{ '@type': 'Person', name: 'Mia Cruz' }])
  })

  it('does not load previously stored off-host cover or organizer logo', async () => {
    mount({ ...baseEvent, image_asset_host: 'storage.invalid',
      cover_image_url: 'https://evil.test/pixel.webp',
      organizer: { business_name: 'Island Studio', slug: 'island-studio', logo_url: 'https://evil.test/logo.webp' } })
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(document.querySelector('img[src^="https://evil.test/"]')).toBeNull()
    expect(seo.props.image).toBeUndefined()
  })

  it('does not apply custom button styles for an invalid stored accent', async () => {
    const { container } = mount({ ...baseEvent, page_customization: { accent: '#12' } })
    await screen.findByRole('heading', { name: 'Reef Night' })
    expect(container.querySelector('.event-customized')).toBeNull()
  })

})
