import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import TransferTicketDialog from './TransferTicketDialog'

describe('TransferTicketDialog', () => {
  it('moves focus into the confirmation and keeps Escape and the focus trap working', async () => {
    const onClose = vi.fn()
    render(<><button type="button">Transfer</button><TransferTicketDialog ticketLabel="your ticket" onSend={() => Promise.resolve()} onClose={onClose} /></>)
    await userEvent.type(screen.getByLabelText('Recipient email'), 'friend@example.com')
    await userEvent.click(screen.getByRole('button', { name: 'Send transfer' }))

    const done = await screen.findByRole('button', { name: 'Done' })
    expect(screen.getByRole('dialog', { name: 'Transfer sent' })).toBeInTheDocument()
    expect(done).toHaveFocus()
    await userEvent.tab()
    expect(done).toHaveFocus()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })
})
