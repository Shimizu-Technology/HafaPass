import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import PayoutAccountReviewQueue from './PayoutAccountReview'
import AdminDashboardPage from '../pages/admin/AdminDashboardPage'
import AdminOrganizationPage from '../pages/admin/AdminOrganizationPage'

vi.mock('../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../pages/admin/AdminLayout', () => ({ default: ({ children }) => <main>{children}</main> }))
vi.mock('./ui/ScrollReveal', () => ({ StaggerContainer: ({ children }) => <div>{children}</div>, StaggerItem: ({ children }) => <div>{children}</div> }))
const account = { id: 11, provider: 'manual', organization_id: 7, organization_name: 'Island Events', owner_email: 'owner@example.test', payout_ready: false,
  payout_details: { bank_name: 'Island Bank', account_holder_name: 'Island Events LLC', masked_account: '••••1234', account_number: 'NEVER_RENDER_FULL_BANK' },
  tax_information: { w9_on_file: true, legal_name: 'Island Events LLC', business_name: 'Island Events', masked_tin: '***-**-5678', tin: 'NEVER_RENDER_FULL_TIN' },
  payout_review: { manual: true, status: 'waiting', missing: [], can_approve: true, review_state_digest: 'digest-1', note: null, review_by: null } }
const dashboard = { total_events: {}, total_users: {}, total_revenue_cents: 0, total_tickets_sold: 0, recent_events: [], recent_orders: [], payout_setups_awaiting_approval: { count: 1, items: [account] } }
const request = () => ({ config: {}, current: () => true, handleError: () => false, release: vi.fn() })
const show = (value = account, onChanged = vi.fn()) => render(<MemoryRouter><PayoutAccountReviewQueue accounts={[value]} beginRequest={request} onChanged={onChanged} /></MemoryRouter>)
const openApproval = async user => { await user.click(screen.getByRole('button', { name: 'Approve payout method' })); return within(screen.getByRole('dialog')) }
const confirmAll = async (user, dialog) => { for (const checkbox of dialog.getAllByRole('checkbox')) await user.click(checkbox) }

let clearAuth
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null })
beforeEach(() => { vi.clearAllMocks(); apiClient.post.mockResolvedValue({ data: account }) })
describe('manual payout review', () => {
  it('requires all human confirmations, uses a 12-month date and sends the exact digest-bound contract once', async () => {
    const user = userEvent.setup(); const onChanged = vi.fn(); show(account, onChanged)
    const dialog = await openApproval(user)
    expect(dialog.getByRole('button', { name: 'Approve payout method' })).toBeDisabled()
    expect(dialog.getByLabelText(/Review again by/).value.slice(0, 4)).toBe(String(new Date().getFullYear() + 1))
    expect(dialog.getByText('••••1234')).toBeVisible()
    expect(document.body).not.toHaveTextContent('NEVER_RENDER_FULL_BANK')
    expect(document.body).not.toHaveTextContent('NEVER_RENDER_FULL_TIN')
    await confirmAll(user, dialog)
    await user.type(dialog.getByLabelText(/Note \(optional/), 'Confirmed by phone')
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/connected_accounts/11/approve_payout_method', {
      controls: { payee_matches: true, details_complete: true, organization_confirmed: true }, note: 'Confirmed by phone', review_by: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), expected_digest: 'digest-1',
    }, {})
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(onChanged).toHaveBeenCalledTimes(1)
    expect(await screen.findByRole('status')).toHaveTextContent('Payout method approved.')
  })
  it('blocks approval with visible missing reasons and requires a nonblank changes note', async () => {
    const user = userEvent.setup(); show({ ...account, payout_review: { ...account.payout_review, can_approve: false, status: 'incomplete', missing: ['Certified W-9 is missing.'] } })
    expect(screen.getByRole('button', { name: 'Approve payout method' })).toBeDisabled()
    expect(screen.getByText('Certified W-9 is missing.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Ask for changes' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByRole('button', { name: 'Send changes request' })).toBeDisabled()
    await user.type(dialog.getByLabelText(/What needs to change/), '  Please certify your W-9.  ')
    await user.click(dialog.getByRole('button', { name: 'Send changes request' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/connected_accounts/11/request_payout_changes', { note: 'Please certify your W-9.', expected_digest: 'digest-1' }, {})
  })
  it('keeps the review and note after validation failure and supports retry', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { errors: ['Review date is too far away.'] } } })
    const user = userEvent.setup(); show(); const dialog = await openApproval(user); await confirmAll(user, dialog)
    await user.type(dialog.getByLabelText(/Note \(optional/), 'Checked in person')
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(await dialog.findByRole('alert')).toHaveTextContent('Review date is too far away.')
    expect(dialog.getByLabelText(/Note \(optional/)).toHaveValue('Checked in person')
    expect(dialog.getAllByRole('checkbox').every(input => input.checked)).toBe(true)
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(await screen.findByRole('status')).toHaveTextContent('Payout method approved.')
  })
  it('shows a stale-details recovery message instead of retrying with a new digest automatically', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 409 } })
    const user = userEvent.setup(); const refresh = vi.fn(); show(account, refresh); const dialog = await openApproval(user); await confirmAll(user, dialog)
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(await dialog.findByRole('alert')).toHaveTextContent('Close this dialog and refresh')
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(dialog.getByRole('button', { name: 'Approve payout method' })).toBeDisabled()
    await user.click(dialog.getByRole('button', { name: 'Close and refresh' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(refresh).toHaveBeenCalledTimes(1)
  })
  it('traps keyboard focus, closes on Escape and restores the trigger', async () => {
    const user = userEvent.setup(); show(); const trigger = screen.getByRole('button', { name: 'Approve payout method' })
    const dialog = await openApproval(user)
    expect(dialog.getAllByRole('checkbox')[0]).toHaveFocus()
    await user.tab({ shift: true }); expect(dialog.getByRole('button', { name: 'Cancel' })).toHaveFocus()
    await user.tab(); expect(dialog.getAllByRole('checkbox')[0]).toHaveFocus()
    await user.keyboard('{Escape}'); expect(screen.queryByRole('dialog')).not.toBeInTheDocument(); expect(trigger).toHaveFocus()
  })
  it('prevents duplicate submits and dismissal while saving', async () => {
    let resolve; apiClient.post.mockReturnValueOnce(new Promise(done => { resolve = done }))
    const user = userEvent.setup(); show(); const dialog = await openApproval(user); await confirmAll(user, dialog)
    await user.dblClick(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(dialog.getByRole('button', { name: 'Cancel' })).toBeDisabled()
    await user.keyboard('{Escape}'); expect(screen.getByRole('dialog')).toBeInTheDocument()
    await act(async () => resolve({ data: account }))
  })
  it('keeps nonmanual evidence under Advanced with no simple approval', async () => {
    const user = userEvent.setup(); show({ ...account, provider: 'paypal', payout_review: { ...account.payout_review, manual: false } })
    expect(screen.queryByRole('button', { name: 'Approve payout method' })).not.toBeInTheDocument()
    await user.click(screen.getByText('Advanced'))
    await user.click(screen.getByRole('button', { name: 'Submit payout evidence' }))
    expect(screen.getByRole('dialog', { name: 'paypal payment readiness' })).toBeVisible()
  })
  it('refreshes the dashboard queue after approval', async () => {
    apiClient.get.mockResolvedValueOnce({ data: dashboard }).mockResolvedValue({ data: { ...dashboard, payout_setups_awaiting_approval: { count: 0, items: [] } } })
    const user = userEvent.setup(); render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    await screen.findByRole('heading', { name: 'Payout setups awaiting approval (1)' })
    const dialog = await openApproval(user); await confirmAll(user, dialog); await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    expect(await screen.findByRole('heading', { name: 'Payout setups awaiting approval (0)' })).toBeInTheDocument()
  })
  it.each(['success', 'failure'])('discards a late approval %s after the same admin changes session', async outcome => {
    let resolve, reject
    const pending = new Promise((yes, no) => { resolve = yes; reject = no })
    clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'admin-a', sessionId: 'session-a', ready: true })
    apiClient.get.mockResolvedValue({ data: dashboard })
    apiClient.post.mockReturnValueOnce(pending)
    const user = userEvent.setup(); render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    await screen.findByRole('heading', { name: 'Payout setups awaiting approval (1)' })
    const dialog = await openApproval(user); await confirmAll(user, dialog)
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    const config = apiClient.post.mock.calls[0][2]
    await act(async () => { clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'admin-a', sessionId: 'session-b', ready: true }) })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await screen.findByRole('button', { name: 'Approve payout method' })
    const reads = apiClient.get.mock.calls.length
    await act(async () => outcome === 'success' ? resolve({ data: account }) : reject(new Error('Old-session failure')))
    expect(screen.queryByText('Payout method approved.')).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(reads)
    expect(config.authContext.sessionId).toBe('session-a')
    expect(config.signal.aborted).toBe(true)
  })
  it('offers the same action on the organization and reloads its saved review', async () => {
    let approved = false
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/memberships') ? [] : { id: 7, name: 'Island Events', memberships: [], payout_accounts: [{ ...account, payout_review: { ...account.payout_review, status: approved ? 'approved' : 'waiting', can_approve: !approved } }] } }))
    apiClient.post.mockImplementation(async () => { approved = true; return { data: account } })
    const user = userEvent.setup(); render(<MemoryRouter initialEntries={['/admin/organizations/7']}><Routes><Route path="/admin/organizations/:id" element={<AdminOrganizationPage />} /></Routes></MemoryRouter>)
    await screen.findByRole('heading', { name: 'Payout accounts' }); const dialog = await openApproval(user); await confirmAll(user, dialog)
    await user.click(dialog.getByRole('button', { name: 'Approve payout method' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Approve payout method' })).toBeDisabled())
    expect(screen.getByText('Payout method approved')).toBeInTheDocument()
  })
})
