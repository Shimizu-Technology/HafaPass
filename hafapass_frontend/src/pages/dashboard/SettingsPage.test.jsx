import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import SettingsPage from './SettingsPage'

vi.mock('../../api/client', () => ({
  default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

describe('SettingsPage', () => {
  beforeEach(() => {
    apiClient.get.mockImplementation(path => {
      if (path === '/organizer/organization') return Promise.resolve({ data: {
        id: 7, name: 'Island Events', role: 'owner', payout_ready: false, timezone: 'Pacific/Guam'
      } })
      if (path === '/organizer/memberships') return Promise.resolve({ data: [{
        id: 1, email: 'owner@example.com', name: 'Owner', role: 'owner', status: 'active'
      }] })
      if (path === '/organizer/connected_accounts') return Promise.resolve({ data: [] })
      return Promise.reject(new Error(`Unexpected path ${path}`))
    })
    apiClient.post.mockResolvedValue({ data: {
      id: 2,
      email: 'finance@example.com',
      role: 'finance',
      status: 'invited',
      invitation_token: 'signed-invitation'
    } })
  })

  it('shows evidence-based payout choices and creates an email-bound team invitation', async () => {
    render(<MemoryRouter><SettingsPage /></MemoryRouter>)

    await screen.findByText('Island Events')
    expect(screen.getByText('Payout setup incomplete')).toBeInTheDocument()
    expect(screen.getByText(/Blocked unless Stripe confirms Guam/)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Teammate email'), { target: { value: 'finance@example.com' } })
    fireEvent.change(screen.getByLabelText('Team role'), { target: { value: 'finance' } })
    fireEvent.click(screen.getByRole('button', { name: 'Invite' }))

    await screen.findByText('Secure invitation link')
    expect(screen.getByLabelText('Invitation link').value).toContain('signed-invitation')
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/memberships', {
      email: 'finance@example.com', role: 'finance'
    }))
  })
})
