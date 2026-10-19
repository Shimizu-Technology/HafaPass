import { act, render, screen, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import EventDetailPage from './EventDetailPage'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, userId: null }) }))
vi.mock('framer-motion', async original => ({ ...(await original()), useReducedMotion: () => true }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => children }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
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

describe('EventDetailPage buyer polish', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    observers = []
    vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)
  })
  afterEach(() => vi.unstubAllGlobals())

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
    reportAllOutOfView()
    expect(bar).toHaveAttribute('data-visible', 'true')
    expect(bar).not.toHaveAttribute('inert')
    expect(within(bar).getByText('From $15.00')).toBeInTheDocument()
    const link = within(bar).getByRole('link', { name: /Get tickets/ })
    expect(link).toHaveAttribute('href', '#tickets')
    const panel = document.getElementById('tickets')
    panel.scrollIntoView = vi.fn()
    link.click()
    expect(panel.scrollIntoView).toHaveBeenCalled()
    expect(panel).toHaveFocus()
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
})
