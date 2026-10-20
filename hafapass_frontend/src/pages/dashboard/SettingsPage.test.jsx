import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import SettingsPage from './SettingsPage'

vi.mock('../../api/client', async importOriginal => ({
  ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() },
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
    render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)

    await screen.findByText('Island Events')
    expect(screen.getByText('Payout setup incomplete')).toBeInTheDocument()
    expect(screen.getByText(/Unavailable unless Stripe confirms Guam/)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Teammate email'), { target: { value: 'finance@example.com' } })
    fireEvent.change(screen.getByLabelText('Team role'), { target: { value: 'finance' } })
    fireEvent.click(screen.getByRole('button', { name: 'Invite' }))

    await screen.findByText('Secure invitation link')
    expect(screen.getByLabelText('Invitation link').value).toContain('signed-invitation')
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/memberships', {
      email: 'finance@example.com', role: 'finance'
    }, expect.objectContaining({ organizationId: null, signal: expect.any(AbortSignal) })))
  })

it('retains the assisted continuation and unmet requirements after settings reload', async () => {
  const account = { id: 4, provider: 'manual', status: 'onboarding', payout_ready: false, requirements_due: ['bank_account_review'] }
  const originalGet = apiClient.get.getMockImplementation()
  apiClient.get.mockImplementation(path => path === '/organizer/connected_accounts' ? Promise.resolve({ data: [account] }) : originalGet(path))
  const view = render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)
  await screen.findByText('Review status: Onboarding')
  expect(screen.getByText('Still required: Bank Account Review.')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Continue with HåfaPass team' })).toHaveAttribute('href', expect.stringContaining('mailto:'))
  expect(screen.queryByRole('button', { name: 'Start bank review' })).not.toBeInTheDocument()
  view.unmount()
  render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)
  await screen.findByText('Review status: Onboarding')
  expect(screen.getByRole('link', { name: 'Continue with HåfaPass team' })).toBeInTheDocument()
  expect(screen.getByText(/no message is sent by starting a review/)).toBeInTheDocument()
})

})
