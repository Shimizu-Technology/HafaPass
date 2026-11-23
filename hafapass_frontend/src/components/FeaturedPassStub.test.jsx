import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import FeaturedPassStub from './FeaturedPassStub'

const event = {
  id: 7,
  slug: 'reef-night',
  title: 'Reef night',
  starts_at: '2099-10-20T08:00:00Z',
  timezone: 'Pacific/Guam',
  venue_name: 'Ypao Beach Park',
  venue_city: 'Tumon',
  ticket_types: [{ price_cents: 2500, all_in_price_cents: 2725, quantity_remaining: 9, on_sale: true }],
}

function Opened() {
  return <p>Opened {useLocation().pathname}</p>
}

const mount = (override = {}) => render(
  <MemoryRouter>
    <Routes>
      <Route path="/" element={<FeaturedPassStub event={{ ...event, ...override }} />} />
      <Route path="/events/:slug" element={<Opened />} />
    </Routes>
  </MemoryRouter>,
)

const pass = () => screen.getByRole('link')

describe('FeaturedPassStub', () => {
  it('shows the real event as one flat, straight link with its date, place and all-in price', () => {
    mount()
    expect(pass()).toHaveAttribute('href', '/events/reef-night')
    expect(pass()).toHaveTextContent('Reef night')
    expect(pass()).toHaveTextContent('Guam time')
    expect(pass()).toHaveTextContent('Ypao Beach Park · Tumon')
    expect(pass()).toHaveTextContent('From $27.25')
    expect(pass().style.transform).toBe('')
    // Cover art is decorative; the title names the pass.
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('opens the event from the keyboard', async () => {
    mount()
    const user = userEvent.setup()
    await user.tab()
    expect(pass()).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })

  it('opens the event on click without tilt interference', async () => {
    mount()
    await userEvent.setup().click(pass())
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })
})
