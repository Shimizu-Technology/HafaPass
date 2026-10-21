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
    expect(screen.getByText('events.salesUnavailable')).toBeInTheDocument()
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
  it('leads with the lowest all-in price including the buyer service fee', () => {
    mount([{ price_cents: 2000, current_price_cents: 2000, all_in_price_cents: 2200, service_fee_cents: 200, quantity_remaining: 3, on_sale: true },
      { price_cents: 1900, current_price_cents: 1900, all_in_price_cents: 2295, service_fee_cents: 395, quantity_remaining: 3, on_sale: true }])
    expect(screen.getByText('events.from $22.00')).toBeInTheDocument()
    expect(screen.queryByText(/\$19.00|\$20.00/)).not.toBeInTheDocument()
  })
})
