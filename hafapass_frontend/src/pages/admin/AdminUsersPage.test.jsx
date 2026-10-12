import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import AdminUsersPage from './AdminUsersPage'
import apiClient from '../../api/client'
vi.mock('../../api/client', async importOriginal => ({
  ...await importOriginal(), default: { get: vi.fn(), patch: vi.fn(), post: vi.fn() } }))
const organizer = {
  id: 7, first_name: 'Test', last_name: 'Organizer', email: 'organizer@example.test', role: 'organizer', orders_count: 12, created_at: '2026-10-01T00:00:00Z',
  organizer_profile: { id: 9, business_name: 'Guam Test Events', verification_status: 'pending', verification_notes: '', payout_ready: false,
    connected_account: { id: 11, provider: 'stripe', status: 'pending', requirements_due: ['independent_readiness_approval'] } },
}
const card = async () => within(await screen.findByRole('article', { name: 'User organizer@example.test' }))
const show = () => render(<MemoryRouter initialEntries={['/admin/users']}><AdminUsersPage /></MemoryRouter>)
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear()
  apiClient.get.mockResolvedValue({ data: { users: [structuredClone(organizer)], meta: { page: 1, total_pages: 1 } } })
})
afterEach(() => vi.restoreAllMocks())

describe('mobile administrator user controls', () => {
  it('exposes verification and independent readiness review in the phone card', async () => {
    show(); const mobile = await card()
    expect(mobile.getByRole('combobox', { name: 'Verification status for Guam Test Events' })).toBeEnabled()
    expect(mobile.getByRole('button', { name: 'Record provider status' })).toBeEnabled()
    expect(mobile.getByRole('button', { name: 'Disable' })).toBeEnabled()
    expect(mobile.getByRole('region', { name: 'Organizer readiness for organizer@example.test' })).not.toHaveClass('hidden')
    await userEvent.click(mobile.getByRole('button', { name: 'Submit Gate B evidence' }))
    expect(await screen.findByRole('dialog', { name: 'stripe payment readiness' })).toBeInTheDocument()
    expect(screen.getByText('Every item must be supported by the referenced evidence—not assumed from a sandbox test.')).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('sends the same verification request and reflects the saved value', async () => {
    apiClient.patch.mockResolvedValue({ data: { verification_status: 'verified', verification_notes: '' } })
    show(); const mobile = await card()
    await userEvent.selectOptions(mobile.getByRole('combobox', { name: 'Verification status for Guam Test Events' }), 'verified')
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/9', { verification_status: 'verified', verification_notes: '' }, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    await waitFor(() => expect(mobile.getByRole('combobox', { name: 'Verification status for Guam Test Events' })).toHaveValue('verified'))
  })
  it('keeps capability sync confirmation separate from independent approval', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    show(); const mobile = await card()
    await userEvent.click(mobile.getByRole('button', { name: 'Record provider status' }))
    expect(confirm).toHaveBeenCalledWith('Record the provider capability sync? Independent Gate B evidence approval will still be required.')
    expect(apiClient.patch).not.toHaveBeenCalled()
    confirm.mockReturnValue(true)
    apiClient.patch.mockResolvedValue({ data: { ...organizer.organizer_profile.connected_account, charges_enabled: true, payouts_enabled: true, details_submitted: true, payout_ready: false, requirements_due: ['independent_readiness_approval'] } })
    await userEvent.click(mobile.getByRole('button', { name: 'Record provider status' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/connected_accounts/11', { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] }, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    await waitFor(() => expect(mobile.getByRole('button', { name: 'Submit Gate B evidence' })).toBeEnabled())
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('preserves confirmation before promoting a user to admin', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    show(); const mobile = await card()
    await userEvent.selectOptions(mobile.getByRole('combobox', { name: 'Role for organizer@example.test' }), 'admin')
    expect(confirm).toHaveBeenCalledWith('Promote organizer@example.test to admin? This grants full platform access.')
    expect(apiClient.patch).not.toHaveBeenCalled()
  })
})

describe('users without provider contact data', () => {
  it('identifies each desktop and mobile row and never asks to promote null', async () => {
    apiClient.get.mockResolvedValue({ data: { users: [7, 8].map(id => ({ id, email: null, first_name: null, last_name: null, role: 'attendee', created_at: '2026-10-01', orders_count: 0 })), meta: {} } })
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    show()
    const rows = await screen.findAllByRole('combobox', { name: 'Role for User #7' })
    expect(rows).toHaveLength(2)
    expect(screen.getAllByRole('combobox', { name: 'Role for User #8' })).toHaveLength(2)
    expect(screen.getAllByText('Email unavailable')).toHaveLength(4)
    expect(screen.getAllByText('User #7')).toHaveLength(2)
    await userEvent.selectOptions(rows[1], 'admin')
    expect(confirm).toHaveBeenCalledWith('Promote User #7 to admin? This grants full platform access.')
    expect(apiClient.patch).not.toHaveBeenCalled()
  })
})
