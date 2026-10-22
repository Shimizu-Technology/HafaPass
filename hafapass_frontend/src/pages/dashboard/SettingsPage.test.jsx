import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import SettingsPage from './SettingsPage'

vi.mock('../../api/client', async importOriginal => ({
  ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

const ownerPermissions = { manage_members: true, manage_payout_settings: true, manage_organization: true }
let organization
let memberships
let accounts

const show = () => render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)

describe('SettingsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
    organization = { id: 7, name: 'Island Events', role: 'owner', payout_ready: false, timezone: 'Pacific/Guam', permissions: ownerPermissions }
    memberships = [
      { id: 1, email: 'owner@example.com', name: 'Owner', role: 'owner', status: 'active', invitation_status: 'accepted' },
      { id: 3, email: 'manager@example.com', name: 'Mia Manager', role: 'manager', status: 'active', invitation_status: 'accepted' },
      { id: 4, email: 'late@example.com', role: 'finance', status: 'invited', invitation_status: 'expired' },
    ]
    accounts = []
    apiClient.get.mockImplementation(path => {
      if (path === '/config') return Promise.resolve({ data: {} })
      if (path === '/organizer/organization') return Promise.resolve({ data: organization })
      if (path === '/organizer/memberships') return Promise.resolve({ data: memberships })
      if (path === '/organizer/tax_information') return Promise.resolve({ data: { tax_information: null, edit_locked: false, certification: 'Under penalties of perjury, I certify.' } })
      if (path === '/organizer/connected_accounts') return Promise.resolve({ data: accounts })
      return Promise.reject(new Error(`Unexpected path ${path}`))
    })
  })

  it('invites with a described role and offers the secure link as a fallback', async () => {
    apiClient.post.mockResolvedValue({ data: {
      id: 2, email: 'finance@example.com', role: 'finance', status: 'invited', invitation_status: 'pending',
      email_delivery: { status: 'queued', provider: 'resend' }, invitation_token: 'signed-invitation',
    } })
    show()
    await screen.findByText('Island Events')
    expect(screen.getByText('Payout setup incomplete')).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: /Finance.*Sales reports, refunds and payouts\./ })).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Teammate email'), { target: { value: 'finance@example.com' } })
    await userEvent.click(screen.getByRole('radio', { name: /Finance/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Invite' }))

    await screen.findByText('Invitation sent to finance@example.com as Finance.')
    expect(screen.getByLabelText('Invitation link').value).toContain('signed-invitation')
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/memberships', { email: 'finance@example.com', role: 'finance' },
      expect.objectContaining({ organizationId: null, signal: expect.any(AbortSignal) }))
    expect(screen.getByText(/Sending the invitation email/)).toBeInTheDocument()
  })

  it('shows invitation status and resends an expired invitation', async () => {
    apiClient.post.mockResolvedValue({ data: { ...memberships[2], invitation_status: 'pending', invitation_token: 'fresh-token' } })
    show()
    const row = within((await screen.findByText('late@example.com')).closest('li'))
    expect(row.getByText('Invite expired')).toBeInTheDocument()
    await userEvent.click(row.getByRole('button', { name: 'Resend' }))
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/memberships/4/resend', undefined, expect.anything())
    await screen.findByText(/Earlier links no longer work/)
  })

  it('transfers ownership only after confirming in a dialog', async () => {
    apiClient.post.mockResolvedValue({ data: [
      { ...memberships[0], role: 'manager' }, { ...memberships[1], role: 'owner' },
    ] })
    show()
    const row = within((await screen.findByText('Mia Manager')).closest('li'))
    await userEvent.click(row.getByRole('button', { name: 'Make owner' }))
    const dialog = within(screen.getByRole('dialog', { name: 'Make Mia Manager the owner?' }))
    expect(dialog.getByText(/current owner becomes a Manager/)).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
    await userEvent.click(dialog.getByRole('button', { name: 'Transfer ownership' }))
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/memberships/3/transfer_ownership', undefined, expect.anything())
    await screen.findByText('Mia Manager is now the owner.')
  })

  it('removes a member through a confirmation dialog instead of window.confirm', async () => {
    const confirm = vi.spyOn(window, 'confirm')
    apiClient.delete.mockResolvedValue({})
    show()
    await userEvent.click(await screen.findByRole('button', { name: 'Remove manager@example.com' }))
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Remove access' }))
    expect(apiClient.delete).toHaveBeenCalledWith('/organizer/memberships/3', expect.anything())
    expect(confirm).not.toHaveBeenCalled()
  })

  it('saves check payee details as the standard payout method', async () => {
    apiClient.post.mockResolvedValue({ data: {
      id: 9, provider: 'check', status: 'onboarding', payout_ready: false, requirements_due: ['payee_details_review'],
      payout_details: { payee_name: 'Island Events LLC', delivery_method: 'mail', mailing_address: 'PO Box 1, Hagåtña' },
      next_action: 'Saved. HåfaPass finance will confirm the payee details.',
    } })
    show()
    await screen.findByRole('heading', { name: 'How you get paid' })
    await userEvent.click(screen.getByRole('button', { name: 'Save check details' }))
    expect(screen.getByText('Enter the name to write on the check.')).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()

    await userEvent.type(screen.getByLabelText('Pay to (name on the check)'), 'Island Events LLC')
    await userEvent.type(screen.getByLabelText('Mailing address'), 'PO Box 1, Hagåtña')
    await userEvent.click(screen.getByRole('button', { name: 'Save check details' }))

    expect(apiClient.post).toHaveBeenCalledWith('/organizer/connected_accounts', {
      provider: 'check', payout_details: expect.objectContaining({ payee_name: 'Island Events LLC', delivery_method: 'mail', mailing_address: 'PO Box 1, Hagåtña' }),
    }, expect.anything())
    await screen.findByText('Saved — waiting for HåfaPass review')
    expect(screen.getByText('HåfaPass finance checks who the check is made out to')).toBeInTheDocument()
  })

  it('keeps an assisted bank transfer status after reload', async () => {
    accounts = [{ id: 4, provider: 'manual', status: 'onboarding', payout_ready: false, requirements_due: ['bank_account_review'] }]
    show()
    await screen.findByText('HåfaPass finance reviews your bank details')
    expect(screen.getByRole('radio', { name: /Bank transfer/ })).toBeChecked()
    expect(screen.getByRole('link', { name: 'Contact HåfaPass team' })).toHaveAttribute('href', expect.stringContaining('mailto:'))
    expect(screen.queryByRole('button', { name: 'Choose bank transfer' })).not.toBeInTheDocument()
  })

  it('shows the marketing address confirmation beside its form without payout access', async () => {
    organization = { ...organization, permissions: { manage_members: false, manage_payout_settings: false, manage_organization: true } }
    apiClient.patch.mockResolvedValue({ data: { ...organization, marketing_address_ready: true } })
    show()
    const section = (await screen.findByRole('heading', { name: 'Marketing postal address' })).closest('section')
    await userEvent.type(within(section).getByLabelText('Physical postal address'), '123 Marine Drive, Hagåtña, GU 96910')
    await userEvent.click(within(section).getByRole('checkbox'))
    await userEvent.click(within(section).getByRole('button', { name: 'Save marketing address' }))
    expect(await within(section).findByRole('status')).toHaveTextContent('Marketing postal address saved')
    expect(screen.queryByRole('heading', { name: 'How you get paid' })).not.toBeInTheDocument()
  })

  it('shows a calm no-access state to roles without team or payout rights', async () => {
    organization = { ...organization, role: 'marketer', permissions: { manage_members: false, manage_payout_settings: false } }
    show()
    expect(await screen.findByText('Settings are for the organization owner')).toBeInTheDocument()
    expect(screen.getByText('Ask your organization owner if you need it.')).toBeInTheDocument()
    expect(screen.getByText(/Your role: Marketer/)).toBeInTheDocument()
    await waitFor(() => expect(apiClient.get).not.toHaveBeenCalledWith('/organizer/memberships', expect.anything()))
  })
})
