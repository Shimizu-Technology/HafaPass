import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import TeamManager from './TeamManager'

const props = { basePath: '/organizer/memberships', request: vi.fn(), memberships: [
  { id: 1, email: 'ended@example.com', role: 'scanner', status: 'active', invitation_status: 'access_ended', expires_at: '2025-01-01T00:00:00Z' },
] }

describe('TeamManager access and invitation limits', () => {
  it('shows effective access separately from stored membership status', () => {
    render(<TeamManager {...props} />)
    expect(screen.getByText('Access ended')).toBeInTheDocument()
    expect(screen.getByText('Access ended Jan 1, 10:00 AM Guam time')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Remove ended@example.com' }))
    expect(screen.getByRole('button', { name: 'Remove access' })).toBeInTheDocument()
    expect(screen.getAllByText(/Scanner phones that are offline keep working/)).toHaveLength(2)
  })

  it('preserves invitation choices and displays a friendly quota refusal', async () => {
    const request = vi.fn().mockRejectedValue({ response: { status: 422, data: { error: 'An invitation was just sent to this email. Wait a minute before resending, or copy the invitation link.' } } })
    render(<TeamManager {...props} request={request} />)
    fireEvent.change(screen.getByLabelText('Teammate email'), { target: { value: 'door+staff@example.com' } })
    fireEvent.click(screen.getByRole('button', { name: 'Invite' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Wait a minute before resending')
    expect(screen.getByLabelText('Teammate email')).toHaveValue('door+staff@example.com')
    expect(screen.getByRole('button', { name: 'Invite' })).toBeEnabled()
  })
})
