import { StrictMode } from 'react'
import { act, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
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
  it('submits an organization token only once during StrictMode effect replay', async () => {
    apiClient.post.mockResolvedValue({ data: { organization_id: 4, organization_name: 'Strict team', role: 'finance' } })
    render(<StrictMode><MemoryRouter initialEntries={['/organization-invitations/accept?token=strict']}><InvitationAcceptPage /></MemoryRouter></StrictMode>)
    expect(await screen.findByRole('heading', { name: 'You joined Strict team' })).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it('discards a late acceptance after a newer organization selection', async () => {
    let finish
    apiClient.post.mockReturnValue(new Promise(resolve => { finish = resolve }))
    render(<MemoryRouter initialEntries={['/organization-invitations/accept?token=slow']}><InvitationAcceptPage /></MemoryRouter>)
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    window.localStorage.setItem('hafapass_organization_id', '9')
    await act(async () => finish({ data: { organization_id: 4, organization_name: 'Stale team' } }))
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('9')
    expect(screen.queryByText('You joined Stale team')).not.toBeInTheDocument()
  })

  it('discards an old token response after navigation to another invitation', async () => {
    let navigate, finishOld
    const old = new Promise(resolve => { finishOld = resolve })
    apiClient.post.mockImplementation((path, body) => body.token === 'old' ? old
      : Promise.resolve({ data: { organization_id: 9, organization_name: 'Current team' } }))
    function Page() { navigate = useNavigate(); return <InvitationAcceptPage /> }
    render(<MemoryRouter initialEntries={['/organization-invitations/accept?token=old']}><Page /></MemoryRouter>)
    await act(async () => navigate('/organization-invitations/accept?token=new'))
    expect(await screen.findByText('You joined Current team')).toBeInTheDocument()
    await act(async () => finishOld({ data: { organization_id: 4, organization_name: 'Old team' } }))
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('9')
    expect(screen.queryByText('You joined Old team')).not.toBeInTheDocument()
  })

  it('discards a late response when the authenticated account changes', async () => {
    let finish
    apiClient.post.mockReturnValue(new Promise(resolve => { finish = resolve }))
    const view = render(<MemoryRouter initialEntries={['/organization-invitations/accept?token=slow-account']}><InvitationAcceptPage /></MemoryRouter>)
    let cleanup
    await act(async () => { cleanup = setAuthTokenGetter(async () => 'test-only', { userId: 'new-account', sessionId: 'new-session', ready: true }) })
    await act(async () => finish({ data: { organization_id: 4, organization_name: 'Previous account team' } }))
    expect(window.localStorage.getItem('hafapass_organization_id')).toBeNull()
    expect(screen.queryByText('You joined Previous account team')).not.toBeInTheDocument()
    view.unmount()
    await act(async () => cleanup())
  })

})
