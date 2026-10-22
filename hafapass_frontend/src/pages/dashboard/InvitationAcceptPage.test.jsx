import { StrictMode } from 'react'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import InvitationAcceptPage from './InvitationAcceptPage'
import PlatformInvitationAcceptPage from '../PlatformInvitationAcceptPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { post: vi.fn() } }))

describe('invitation acceptance', () => {
  beforeEach(() => { vi.clearAllMocks(); window.localStorage.clear() })

  it('explains the role and sends door staff straight to their event', async () => {
    apiClient.post.mockResolvedValue({ data: { organization_id: 4, organization_name: 'Night Market Co', role: 'scanner',
      role_label: 'Door scanner', role_description: 'scans tickets at assigned events only', events: [{ id: 9, title: 'Night Market' }] } })
    render(<MemoryRouter initialEntries={['/organization-invitations/accept?token=abc']}><InvitationAcceptPage /></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'You joined Night Market Co' })).toBeInTheDocument()
    expect(screen.getByText(/scans tickets at assigned events only/)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Start scanning' })).toHaveAttribute('href', '/dashboard/scanner?event=9')
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('4')
  })

  it('explains what to do when an invitation no longer works', async () => {
    apiClient.post.mockRejectedValue({ response: { data: { error: 'Invitation is invalid or expired' } } })
    render(<MemoryRouter initialEntries={['/organization-invitations/accept?token=abc']}><InvitationAcceptPage /></MemoryRouter>)
    expect(await screen.findByText('Invitation is invalid or expired')).toBeInTheDocument()
    expect(screen.getByText(/Ask the person who invited you to resend it/)).toBeInTheDocument()
  })

  it('applies a staff invitation and opens the right console', async () => {
    apiClient.post.mockResolvedValue({ data: { role: 'support', invited_role: 'support', role_label: 'Support', role_description: 'helps buyers with orders and tickets, no money or settings' } })
    render(<MemoryRouter initialEntries={['/platform-invitations/accept?token=abc']}><PlatformInvitationAcceptPage /></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Welcome to the HåfaPass team' })).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/platform_invitations/accept', { token: 'abc' })
    expect(screen.getByRole('link', { name: 'Open support' })).toHaveAttribute('href', '/support')
  })

  it('submits a one-time token once even when StrictMode replays the effect', async () => {
    apiClient.post.mockResolvedValue({ data: { role: 'support', invited_role: 'support', role_label: 'Support', role_description: 'helps buyers' } })
    render(<StrictMode><MemoryRouter initialEntries={['/platform-invitations/accept?token=once']}><PlatformInvitationAcceptPage /></MemoryRouter></StrictMode>)
    expect(await screen.findByRole('heading', { name: 'Welcome to the HåfaPass team' })).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(screen.queryByText('Invitation unavailable')).not.toBeInTheDocument()
  })
})
