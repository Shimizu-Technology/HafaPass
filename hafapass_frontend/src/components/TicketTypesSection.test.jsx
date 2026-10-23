import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import TicketTypesSection from './TicketTypesSection'
vi.mock('../utils/workspace', () => ({ useAccountRole: () => null }))
const config = vi.hoisted(() => ({ adminOnly: false }))
vi.mock('../hooks/usePaidCheckoutAdminOnly', () => ({ default: enabled => enabled && config.adminOnly }))

describe('ticket selection with changing availability', () => {
  it('clears closed selections from the displayed total and checkout request', async () => {
    const checkout = vi.fn()
    const a = { id: 1, name: 'VIP table admission', price_cents: 2000, current_price_cents: 1250, quantity_remaining: 2, on_sale: true }
    const b = { id: 2, name: 'Standard entry', price_cents: 500, quantity_remaining: 5, on_sale: true }
    const { rerender } = render(<TicketTypesSection ticketTypes={[a, b]} onCheckout={checkout} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Increase quantity for VIP table admission' }))
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Standard entry' }))
    expect(screen.getByRole('button', { name: /Buy Tickets/ })).toHaveTextContent('$17.50')
    rerender(<TicketTypesSection ticketTypes={[{ ...a, on_sale: false }, b]} onCheckout={checkout} />)
    expect(screen.queryByRole('button', { name: 'Increase quantity for VIP table admission' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Buy Tickets/ })).toHaveTextContent('$5.00')
    await user.click(screen.getByRole('button', { name: /Buy Tickets/ }))
    expect(checkout).toHaveBeenCalledWith([{ ticket_type_id: 2, quantity: 1 }])
  })
  it('clamps selected inventory after availability falls, and removes the action when all tickets sell out', async () => {
    const ticket = { id: 1, name: 'Entry', price_cents: 1250, quantity_remaining: 3, on_sale: true }
    const checkout = vi.fn()
    const { rerender } = render(<TicketTypesSection ticketTypes={[ticket]} onCheckout={checkout} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Entry' }))
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Entry' }))
    rerender(<TicketTypesSection ticketTypes={[{ ...ticket, quantity_remaining: 1 }]} onCheckout={checkout} />)
    await user.click(screen.getByRole('button', { name: /Buy Tickets/ }))
    expect(checkout).toHaveBeenCalledWith([{ ticket_type_id: 1, quantity: 1 }])
    rerender(<TicketTypesSection ticketTypes={[{ ...ticket, quantity_remaining: 0 }]} onCheckout={checkout} />)
    expect(screen.queryByRole('button', { name: /Buy Tickets/ })).not.toBeInTheDocument()
  })
  it('shows ticket prices in neutral text rather than an alert color', () => {
    render(<TicketTypesSection ticketTypes={[
      { id: 1, name: 'Entry', price_cents: 1250, quantity_remaining: 3, on_sale: true },
      { id: 2, name: 'Early bird', price_cents: 2000, current_price_cents: 1500, active_tier: { name: 'Early' }, quantity_remaining: 3, on_sale: true },
    ]} onCheckout={vi.fn()} />)
    for (const price of [screen.getByText('$12.50'), screen.getByText('Early — $15.00')]) {
      expect(price).toHaveClass('text-neutral-900', 'font-semibold')
      expect(price.className).not.toMatch(/accent|red|action/)
    }
  })

  it('leads with all-in prices and totals, with the fee as a secondary line', async () => {
    const checkout = vi.fn()
    render(<TicketTypesSection ticketTypes={[
      { id: 1, name: 'General', price_cents: 1999, current_price_cents: 1999, all_in_price_cents: 2199, service_fee_cents: 200, quantity_remaining: 9, on_sale: true },
      { id: 2, name: 'Child', price_cents: 0, current_price_cents: 0, all_in_price_cents: 0, service_fee_cents: 0, quantity_remaining: 9, on_sale: true },
    ]} onCheckout={checkout} />)
    expect(screen.getByText('$21.99')).toHaveClass('font-semibold')
    expect(screen.getByText('$19.99 ticket + $2.00 service fee')).toBeInTheDocument()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Increase quantity for General' }))
    await user.click(screen.getByRole('button', { name: 'Increase quantity for General' }))
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Child' }))
    expect(screen.getByRole('button', { name: /Buy Tickets/ })).toHaveTextContent('$43.98')
    expect(screen.queryByTestId('buy-total-fee')).not.toBeInTheDocument()
  })
  it('shows the ticket price alone, with no fee line, when the organizer absorbs the fee', () => {
    render(<TicketTypesSection ticketTypes={[
      { id: 1, name: 'General', price_cents: 2500, current_price_cents: 2500, all_in_price_cents: 2500, service_fee_cents: 0, quantity_remaining: 9, on_sale: true },
    ]} onCheckout={vi.fn()} />)
    expect(screen.getByText('$25.00')).toBeInTheDocument()
    expect(screen.queryByText(/pricing.ticketPlusFee/)).not.toBeInTheDocument()
  })
  it('does not repeat the regular price when the next tier returns to it', () => {
    render(<TicketTypesSection ticketTypes={[{ id: 3, name: 'Early', price_cents: 2000, current_price_cents: 1500,
      all_in_price_cents: 1675, service_fee_cents: 175, regular_all_in_price_cents: 2200, active_tier: { name: 'Early bird' },
      next_tier: { name: 'Regular', price_cents: 2000, all_in_price_cents: 2200 }, quantity_remaining: 5, on_sale: true }]} onCheckout={vi.fn()} />)
    expect(screen.getAllByText(/\$22\.00/)).toHaveLength(1)
    expect(screen.queryByText(/pricing.regularPrice/)).not.toBeInTheDocument()
  })

  it('keeps free tickets buyable but says paid sales open soon when paid checkout is locked', async () => {
    const checkout = vi.fn()
    const paid = { id: 1, name: 'Entry', price_cents: 1250, quantity_remaining: 3, on_sale: true }
    const free = { id: 2, name: 'Kids', price_cents: 0, quantity_remaining: 3, on_sale: true }
    config.adminOnly = true
    render(<TicketTypesSection ticketTypes={[paid, free]} onCheckout={checkout} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Kids' }))
    await user.click(screen.getByRole('button', { name: /Buy Tickets/ }))
    expect(checkout).toHaveBeenCalledWith([{ ticket_type_id: 2, quantity: 1 }])
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Entry' }))
    expect(screen.getByRole('status')).toHaveTextContent("Paid ticket sales open soon")
    expect(screen.queryByRole('button', { name: /Buy Tickets/ })).not.toBeInTheDocument()
    config.adminOnly = false
  })
})

it.each([1, 2])('labels the next tier and uses the correct day plural (%s)', days => {
  render(<TicketTypesSection ticketTypes={[{ id: 3, name: 'Entry', price_cents: 3000, current_price_cents: 1500,
    active_tier: { name: 'Early', tier_type: 'time_based', ends_at: new Date(Date.now() + days * 86400000 - 60000).toISOString() },
    next_tier: { name: 'Second release', price_cents: 2000 }, quantity_remaining: 5, on_sale: true }]} onCheckout={vi.fn()} />)
  expect(screen.getByText('Next price: $20.00')).toBeInTheDocument()
  expect(screen.getByText(`Ends in ${days} ${days === 1 ? 'day' : 'days'}`)).toBeInTheDocument()
})
