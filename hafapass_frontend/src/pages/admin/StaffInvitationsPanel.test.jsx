import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import StaffInvitationsPanel from './StaffInvitationsPanel'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))

const beginRequest = () => ({ config: {}, current: () => true, handleError: () => false, release: () => {} })
const show = () => render(<MemoryRouter><StaffInvitationsPanel beginRequest={beginRequest} /></MemoryRouter>)

describe('StaffInvitationsPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: { invitations: [
      { id: 1, email: 'old@example.com', role: 'support', status: 'expired', email_delivery: null },
    ] } })
  })

  it('loads nothing until opened, then invites Support or Admin by email', async () => {
    apiClient.post.mockResolvedValue({ data: { id: 2, email: 'helper@example.com', role: 'support', status: 'pending', accept_url: 'https://hafapass.test/platform-invitations/accept?token=t', email_delivery: { status: 'queued', provider: 'resend' } } })
    show()
    expect(apiClient.get).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Invite staff' }))
    expect(screen.getByRole('radio', { name: /Support.*no money or settings/ })).toBeChecked()
    await userEvent.click(screen.getByRole('radio', { name: /Admin.*Runs HåfaPass/ }))
    expect(screen.getByText(/Admins have full platform access/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('radio', { name: /Support/ }))
    await userEvent.type(screen.getByLabelText('Email'), 'helper@example.com')
    await userEvent.click(screen.getByRole('button', { name: 'Send invitation' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_invitations', { email: 'helper@example.com', role: 'support' }, expect.anything())
    await screen.findByText(/Their access starts when they sign in with that email/)
    expect(screen.getByLabelText('Invitation link').value).toContain('/platform-invitations/accept')
  })

  it('resends an expired invitation', async () => {
    apiClient.post.mockResolvedValue({ data: { id: 1, email: 'old@example.com', role: 'support', status: 'pending', accept_url: 'https://x.test/a' } })
    show()
    await userEvent.click(screen.getByRole('button', { name: 'Invite staff' }))
    const list = within(await screen.findByRole('list', { name: 'Open staff invitations' }))
    expect(list.getByText('Invite expired')).toBeInTheDocument()
    await userEvent.click(list.getByRole('button', { name: 'Resend' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_invitations/1/resend', {}, expect.anything())
  })
})
