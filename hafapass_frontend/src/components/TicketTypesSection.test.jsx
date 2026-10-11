import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import TicketTypesSection from './TicketTypesSection'
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))

describe('ticket selection with changing availability', () => {
  it('clears closed selections from the displayed total and checkout request', async () => {
    const checkout = vi.fn()
    const a = { id: 1, name: 'VIP table admission', price_cents: 2000, current_price_cents: 1250, quantity_remaining: 2, on_sale: true }
    const b = { id: 2, name: 'Standard entry', price_cents: 500, quantity_remaining: 5, on_sale: true }
    const { rerender } = render(<TicketTypesSection ticketTypes={[a, b]} onCheckout={checkout} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Increase quantity for VIP table admission' }))
    await user.click(screen.getByRole('button', { name: 'Increase quantity for Standard entry' }))
    expect(screen.getByRole('button', { name: /eventDetail.buyTickets/ })).toHaveTextContent('$17.50')
    rerender(<TicketTypesSection ticketTypes={[{ ...a, on_sale: false }, b]} onCheckout={checkout} />)
    expect(screen.queryByRole('button', { name: 'Increase quantity for VIP table admission' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /eventDetail.buyTickets/ })).toHaveTextContent('$5.00')
    await user.click(screen.getByRole('button', { name: /eventDetail.buyTickets/ }))
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
    await user.click(screen.getByRole('button', { name: /eventDetail.buyTickets/ }))
    expect(checkout).toHaveBeenCalledWith([{ ticket_type_id: 1, quantity: 1 }])
    rerender(<TicketTypesSection ticketTypes={[{ ...ticket, quantity_remaining: 0 }]} onCheckout={checkout} />)
    expect(screen.queryByRole('button', { name: /eventDetail.buyTickets/ })).not.toBeInTheDocument()
  })
})
