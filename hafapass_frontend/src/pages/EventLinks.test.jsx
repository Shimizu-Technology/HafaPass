import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import EventDetailPage from './EventDetailPage'
import VenuePage from './VenuePage'
import OrganizerPage from './OrganizerPage'
import CollectionPage from './CollectionPage'
import NotFound from '../components/NotFound'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, userId: null }) }))
vi.mock('framer-motion', async original => ({ ...(await original()), useReducedMotion: () => true }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => children }))
vi.mock('../utils/marketplaceAttribution', () => ({ captureQueryAttribution: vi.fn(), trackFunnel: vi.fn() }))

const event = {
  id: 7, slug: 'reef-night-2099', title: 'Reef Night', description: 'Snorkel social', status: 'published', purchasable: true,
  category: 'nightlife', category_label: 'Nightlife', timezone: 'Pacific/Guam', starts_at: '2099-10-20T08:00:00Z',
  venue_name: 'Tumon Bay Pavilion', attendee_count: 0, attendees_preview: [],
  ticket_types: [{ id: 1, name: 'General', price_cents: 1500, on_sale: true, quantity_remaining: 20 }],
}

function CurrentLocation() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

function mount(path) {
  return render(<MemoryRouter initialEntries={[path]}>
    <Routes>
      <Route path="/events/:slug" element={<EventDetailPage />} />
      <Route path="/venues/:slug" element={<VenuePage />} />
      <Route path="/organizers/:slug" element={<OrganizerPage />} />
      <Route path="/collections/:slug" element={<CollectionPage />} />
      <Route path="/events" element={<p>Events list</p>} />
      <Route path="*" element={<NotFound />} />
    </Routes>
    <CurrentLocation />
  </MemoryRouter>)
}

beforeEach(() => {
  vi.clearAllMocks()
  globalThis.IntersectionObserver = class { observe() {} disconnect() {} }
})

describe('old event links', () => {
  it('swaps the address to the current link without reloading the event', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, redirected_from: 'reef-night' } })
    mount('/events/reef-night?utm_source=poster')

    expect(await screen.findByRole('heading', { name: 'Reef Night' })).toBeInTheDocument()
    expect(screen.getByTestId('location')).toHaveTextContent('/events/reef-night-2099?utm_source=poster')
    expect(apiClient.get.mock.calls.filter(([url]) => url.startsWith('/events/'))).toEqual([['/events/reef-night']])
  })

  it('still rejects a response for a different event that is not a redirect', async () => {
    apiClient.get.mockResolvedValue({ data: event })
    mount('/events/reef-night')

    expect(await screen.findByRole('button', { name: 'Retry event' })).toBeInTheDocument()
    expect(screen.getByTestId('location')).toHaveTextContent('/events/reef-night')
  })

  it('shows the not-found page for a missing event, with search and browse', async () => {
    apiClient.get.mockRejectedValue({ response: { status: 404 } })
    const user = userEvent.setup()
    mount('/events/never-existed')

    expect(await screen.findByRole('heading', { name: 'We couldn’t find that event' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Browse events' })).toHaveAttribute('href', '/events')
    expect(screen.getByRole('link', { name: 'Go to home' })).toHaveAttribute('href', '/')
    await user.type(screen.getByRole('searchbox', { name: 'Search events' }), 'reef night')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    expect(screen.getByTestId('location')).toHaveTextContent('/events?search=reef%20night')
  })
})

describe('other public pages', () => {
  it('swaps an old venue link to the current one without a second request', async () => {
    apiClient.get.mockResolvedValue({ data: { id: 3, name: 'Tumon Hall', slug: 'tumon-grand-hall', village: 'Tumon',
      address: '1 Beach Rd', redirected_from: 'tumon-hall', events: [], meta: { page: 1, pages: 1 } } })
    mount('/venues/tumon-hall')

    expect(await screen.findByRole('heading', { name: 'Tumon Hall' })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('location')).toHaveTextContent('/venues/tumon-grand-hall'))
    expect(apiClient.get).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['/venues/gone', 'We couldn’t find that venue'],
    ['/organizers/gone', 'We couldn’t find that organizer'],
    ['/collections/gone', 'We couldn’t find that collection'],
  ])('shows the shared not-found page for %s', async (path, heading) => {
    apiClient.get.mockRejectedValue({ response: { status: 404 } })
    mount(path)
    expect(await screen.findByRole('heading', { name: heading })).toBeInTheDocument()
  })

  it('offers a retry instead of not-found when a venue fails to load', async () => {
    apiClient.get.mockRejectedValueOnce({ response: { status: 503 } })
      .mockResolvedValueOnce({ data: { id: 3, name: 'Tumon Hall', slug: 'tumon-hall', village: 'Tumon', address: '1 Beach Rd', events: [], meta: { page: 1, pages: 1 } } })
    const user = userEvent.setup()
    mount('/venues/tumon-hall')

    expect(await screen.findByRole('alert')).toHaveTextContent('This venue couldn’t load')
    await user.click(screen.getByRole('button', { name: 'Retry' }))
    expect(await screen.findByRole('heading', { name: 'Tumon Hall' })).toBeInTheDocument()
  })

  it('shows the not-found page for an unknown address', async () => {
    mount('/this/does-not-exist')
    expect(screen.getByRole('heading', { name: 'We couldn’t find that page' })).toBeInTheDocument()
  })
})
