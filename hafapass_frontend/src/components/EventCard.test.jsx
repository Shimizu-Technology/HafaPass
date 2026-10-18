import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'
import EventCard from './EventCard'
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: (key, options) => options?.defaultValue || key }) }))
const event = { id: 1, title: 'Guam event', slug: 'guam-event', status: 'published' }
function mount(tickets) { render(<MemoryRouter><EventCard event={{ ...event, ticket_types: tickets }} /></MemoryRouter>) }
describe('event card availability and prices', () => {
  it('distinguishes unopened or paused sales from exhausted inventory', () => {
    mount([{ price_cents: 1250, quantity_remaining: 20, on_sale: false }])
    expect(screen.getByText('Sales unavailable')).toBeInTheDocument()
    expect(screen.queryByText('events.soldOut')).not.toBeInTheDocument()
    expect(screen.queryByText(/\$12.50/)).not.toBeInTheDocument()
  })
  it('shows sold out when inventory is exhausted', () => {
    mount([{ price_cents: 0, quantity_remaining: 0, on_sale: true }])
    expect(screen.getByText('events.soldOut')).toBeInTheDocument()
    expect(screen.queryByText('events.free')).not.toBeInTheDocument()
  })
  it('prices only the purchasable current tier', () => {
    mount([{ price_cents: 0, quantity_remaining: 0 },
      { price_cents: 2000, current_price_cents: 1250, quantity_remaining: 3, on_sale: true }])
    expect(screen.getByText('events.from $12.50')).toBeInTheDocument()
    expect(screen.getByText('events.ticketsAvailable')).toBeInTheDocument()
  })
})
