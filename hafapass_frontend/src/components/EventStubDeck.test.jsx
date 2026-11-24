import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import EventStubDeck from './EventStubDeck'

const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)', addEventListener: vi.fn(), removeEventListener: vi.fn(),
})))

const sampleEvents = [
  {
    id: 1,
    slug: 'copa-2027',
    title: 'Copa de Marianas 2027 (demo)',
    category: 'sports',
    category_label: 'Sports & Fitness',
    starts_at: '2027-01-30T08:00:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'UOG Calvo Field House',
    venue_city: 'Mangilao',
    ticket_types: [
      { id: 11, price_cents: 0, all_in_price_cents: 0, quantity_remaining: 50, on_sale: true },
      { id: 12, price_cents: 1000, all_in_price_cents: 1150, quantity_remaining: 50, on_sale: true },
    ],
  },
  {
    id: 2,
    slug: 'fd-night-1',
    title: 'FD Alumni Basketball — Night 1 (demo)',
    category: 'sports',
    category_label: 'Sports & Fitness',
    starts_at: '2027-02-12T17:30:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'Phoenix Center Gym',
    venue_city: 'Mangilao',
    ticket_types: [
      { id: 21, price_cents: 1200, all_in_price_cents: 1360, quantity_remaining: 50, on_sale: true },
    ],
  },
]

function Opened() { return <p>Opened {useLocation().pathname}</p> }

const mount = (events = sampleEvents) => render(
  <MemoryRouter>
    <Routes>
      <Route path="/" element={<EventStubDeck events={events} />} />
      <Route path="/events/:slug" element={<Opened />} />
    </Routes>
  </MemoryRouter>
)

afterEach(() => vi.unstubAllGlobals())

describe('EventStubDeck', () => {
  it('renders nothing when fewer than 2 events are available', () => {
    reduceMotion(true)
    const { container } = mount([sampleEvents[0]])
    expect(container).toBeEmptyDOMElement()
  })

  it('shows straight-stacked stubs with blank back cards, mixed pricing, and prev/next + arrow controls', async () => {
    reduceMotion(true)
    mount()
    const deck = screen.getByTestId('event-stub-deck')
    expect(deck).toHaveAttribute('aria-roledescription', 'carousel')
    expect(screen.getByTestId('deck-live-status')).toHaveTextContent('1 of 2: Copa de Marianas 2027 (demo)')
    expect(deck).toHaveTextContent('From $11.50')
    expect(deck).toHaveTextContent('Free tickets available')

    // Only one See tickets link is rendered (back cards are blank stock).
    expect(within(deck).getAllByRole('link', { name: /See tickets/i })).toHaveLength(1)

    const topCard = deck.querySelector('[data-top="true"]')
    expect(topCard.style.transform).toBe('none')
    const backCard = deck.querySelector('[data-top="false"]')
    expect(backCard).toHaveAttribute('aria-hidden', 'true')
    expect(backCard.style.transform).not.toContain('rotate')

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Next featured event' }))
    expect(screen.getByTestId('deck-live-status')).toHaveTextContent('2 of 2: FD Alumni Basketball — Night 1 (demo)')
    expect(deck).toHaveTextContent('From $13.60')

    await user.click(screen.getByRole('button', { name: 'Previous featured event' }))
    expect(screen.getByTestId('deck-live-status')).toHaveTextContent('1 of 2: Copa de Marianas 2027 (demo)')

    deck.focus()
    await user.keyboard('{ArrowRight}')
    expect(screen.getByTestId('deck-live-status')).toHaveTextContent('2 of 2: FD Alumni Basketball — Night 1 (demo)')
  })
})
