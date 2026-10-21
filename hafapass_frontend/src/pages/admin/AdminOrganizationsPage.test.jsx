import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminOrganizationsPage from './AdminOrganizationsPage'
import AdminOrganizationPage from './AdminOrganizationPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const listed = { id: 3, name: 'Ambros Events', owner: { email: 'owner@ambros.test', invitation_status: 'pending' }, members_count: 0,
  pending_invitations_count: 1, verification_status: 'verified', payout_ready: false }
const detail = { ...listed, events_count: 0, organizer_profile: { id: 4, verification_status: 'verified', policy_accepted: false },
  memberships: [{ id: 8, email: 'owner@ambros.test', role: 'owner', status: 'invited', invitation_status: 'pending', email_delivery: { status: 'sent', provider: 'resend' } }] }

describe('Admin organizations', () => {
  beforeEach(() => {
    vi.clearAllMocks(); window.localStorage.clear()
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/admin/organizations'
      ? { organizations: [listed], meta: { page: 1, total_pages: 1, total_count: 1 } }
      : url.endsWith('/memberships') ? detail.memberships : detail }))
  })

  it('creates an organization for someone and shows the owner invitation', async () => {
    apiClient.post.mockResolvedValue({ data: { ...detail, invitation_token: 'owner-token', invitation_url: 'https://hafapass.test/organization-invitations/accept?token=owner-token' } })
    render(<MemoryRouter initialEntries={['/admin/organizations']}><AdminOrganizationsPage /></MemoryRouter>)
    expect(await screen.findByRole('link', { name: /Ambros Events/ })).toHaveAttribute('href', '/admin/organizations/3')

    await userEvent.click(screen.getByRole('button', { name: 'Create organization for someone' }))
    const dialog = within(screen.getByRole('dialog', { name: 'Create an organization for someone' }))
    await userEvent.type(dialog.getByLabelText('Organization name'), 'Ambros Events')
    await userEvent.type(dialog.getByLabelText(/Owner’s email/), 'owner@ambros.test')
    await userEvent.click(dialog.getByRole('checkbox', { name: /Mark as verified now/ }))
    await userEvent.click(dialog.getByRole('button', { name: 'Create and invite owner' }))

    expect(apiClient.post).toHaveBeenCalledWith('/admin/organizations', { name: 'Ambros Events', owner_email: 'owner@ambros.test', pre_verified: true }, expect.anything())
    const done = within(await screen.findByRole('dialog', { name: 'Organization created' }))
    expect(done.getByLabelText('Invitation link').value).toBe('https://hafapass.test/organization-invitations/accept?token=owner-token')
    expect(done.getByRole('link', { name: 'Open Ambros Events' })).toHaveAttribute('href', '/admin/organizations/3')
  })

  it('manages any organization’s team and opens its dashboard as an admin', async () => {
    render(<MemoryRouter initialEntries={['/admin/organizations/3']}><Routes>
      <Route path="/admin/organizations/:id" element={<AdminOrganizationPage />} />
      <Route path="/dashboard" element={<p>Dashboard opened</p>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Ambros Events' })).toBeInTheDocument()
    expect(await screen.findByText('owner@ambros.test', { selector: 'span' })).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/admin/organizations/3/memberships', expect.anything())
    expect(screen.getByRole('radio', { name: /Manager/ })).toBeInTheDocument()
    expect(screen.queryByRole('radio', { name: /^Owner/ })).not.toBeInTheDocument()

    apiClient.patch.mockResolvedValue({ data: {} })
    await userEvent.click(screen.getByRole('button', { name: 'Pause all sales' }))
    const confirm = within(screen.getByRole('dialog', { name: 'Pause all sales for Ambros Events?' }))
    expect(confirm.getByText(/stop selling until you verify them again/)).toBeInTheDocument()
    await userEvent.click(confirm.getByRole('button', { name: 'Pause all sales' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/4', { verification_status: 'suspended' }, expect.anything())

    await userEvent.click(screen.getByRole('button', { name: 'Open its dashboard' }))
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('3')
    expect(await screen.findByText('Dashboard opened')).toBeInTheDocument()
  })
})
