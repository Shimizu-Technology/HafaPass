import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import AttendeesPage from './AttendeesPage'
import SettingsPage from './SettingsPage'
import RefundsPage from './RefundsPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const denied = status => ({ response: { status, data: { error: 'Access revoked', reconciliation_required: false } } })
const event = { id: 37, organization_id: 1, title: 'Authorized event', ticket_types: [], permissions: { view_attendees: true, view_finance: true, refund: true } }
const organization = { id: 1, name: 'Authorized organization', role: 'owner', timezone: 'Pacific/Guam' }
const member = { id: 4, email: 'private.member@example.invalid', name: 'Private member', role: 'manager', status: 'active' }
const attendee = name => ({ id: 7, attendee_name: name, attendee_email: 'private.attendee@example.invalid', status: 'issued', ticket_type: 'Entry' })
const order = { id: 370, buyer_name: 'Private refund buyer', buyer_email: 'private.buyer@example.invalid', ticket_count: 1, total_cents: 500, refundable_cents: 500 }
const journal = { key: 'original-refund-key', orderId: 370, payload: { reason: 'Original private reason', amount_cents: 200 } }
const journalKey = 'hafapass:pending-refund:v2:actor-a:1:37'
let clearAuth
function mount(Page, path) { return render(<MemoryRouter initialEntries={[path]}><Routes><Route path={path.replace('/events/37/', '/events/:id/')} element={<Page />} /></Routes></MemoryRouter>) }
function fixture(url) {
  if (url === '/organizer/organization') return organization
  if (url === '/organizer/memberships') return [member]
  if (url === '/organizer/connected_accounts') return [{ id: 1, provider: 'paypal', status: 'verified', payout_ready: true, requirements_due: ['private_provider_requirement'] }]
  if (url.includes('/attendees')) return { attendees: [attendee('Private attendee')], meta: { total_pages: 1 } }
  if (url.endsWith('/stats')) return { recent_orders: [order] }
  return event
}
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
  for (const method of ['get', 'post', 'patch', 'delete']) apiClient[method].mockReset()
  apiClient.get.mockImplementation(url => Promise.resolve({ data: fixture(url) }))
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

describe('current attendee authorization withdrawal', () => {
  it.each([{ id: 38 }, { organization_id: 2 }])('rejects mismatched event authorization %j before requesting attendees', async mismatch => {
    apiClient.get.mockResolvedValueOnce({ data: { ...event, ...mismatch } })
    mount(AttendeesPage, '/dashboard/events/37/attendees')
    expect(await screen.findByRole('alert')).toHaveTextContent('event context could not be verified')
    expect(apiClient.get.mock.calls.some(([url]) => url.includes('/attendees'))).toBe(false)
  })
  it.each([401, 403])('clears previously visible attendees after a current list %s and verifies permissions before retry reads', async status => {
    mount(AttendeesPage, '/dashboard/events/37/attendees')
    await screen.findAllByText('Private attendee')
    apiClient.get.mockImplementation(url => url.includes('/attendees') ? Promise.reject(denied(status)) : Promise.resolve({ data: fixture(url) }))
    await userEvent.type(screen.getByPlaceholderText('Search by name or email...'), 'new')
    await screen.findByRole('alert')
    expect(screen.queryByText('Private attendee')).not.toBeInTheDocument()
    expect(screen.queryByText('private.attendee@example.invalid')).not.toBeInTheDocument()
    const verify = deferred()
    apiClient.get.mockImplementation(url => url === '/organizer/events/37' ? verify.promise : Promise.resolve({ data: { attendees: [attendee('Fresh attendee')] } }))
    const reads = apiClient.get.mock.calls.filter(([url]) => url.includes('/attendees')).length
    await userEvent.click(screen.getByRole('button', { name: 'Retry attendee list' }))
    expect(apiClient.get.mock.calls.filter(([url]) => url.includes('/attendees'))).toHaveLength(reads)
    await act(async () => verify.resolve({ data: event }))
    await screen.findAllByText('Fresh attendee')
    expect(screen.getByPlaceholderText('Search by name or email...')).toHaveValue('new')
  })
  it.each(['success', 'denial'])('fences an earlier list %s after a newer permission failure and verified retry', async outcome => {
    mount(AttendeesPage, '/dashboard/events/37/attendees'); await screen.findAllByText('Private attendee')
    const old = deferred()
    apiClient.get.mockImplementation(url => url.includes('search=old') ? old.promise : url.includes('search=denied') ? Promise.reject(denied(403)) : Promise.resolve({ data: fixture(url) }))
    await userEvent.type(screen.getByPlaceholderText('Search by name or email...'), 'old')
    await waitFor(() => expect(apiClient.get.mock.calls.some(([url]) => url.includes('search=old'))).toBe(true))
    const oldConfig = apiClient.get.mock.calls.find(([url]) => url.includes('search=old'))[1]
    await userEvent.clear(screen.getByPlaceholderText('Search by name or email...'))
    await userEvent.type(screen.getByPlaceholderText('Search by name or email...'), 'denied')
    await screen.findByRole('alert')
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('/attendees') ? { attendees: [attendee('Fresh attendee')] } : event }))
    await userEvent.click(screen.getByRole('button', { name: 'Retry attendee list' })); await screen.findAllByText('Fresh attendee')
    await act(async () => outcome === 'success' ? old.resolve({ data: { attendees: [attendee('Old unauthorized attendee')] } }) : old.reject(denied(403)))
    expect(oldConfig.signal.aborted).toBe(true)
    expect(screen.queryByText('Old unauthorized attendee')).not.toBeInTheDocument()
    expect(screen.getAllByText('Fresh attendee').length).toBeGreaterThan(0)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
  it('does not fetch attendees after event permission withdrawal or restore access from a metadata outage', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { ...event, permissions: {} } })
    mount(AttendeesPage, '/dashboard/events/37/attendees')
    expect(await screen.findByRole('alert')).toHaveTextContent('does not include viewing attendees')
    expect(apiClient.get.mock.calls.some(([url]) => url.includes('/attendees'))).toBe(false)
    apiClient.get.mockRejectedValue(new Error('Synthetic metadata outage'))
    await userEvent.click(screen.getByRole('button', { name: 'Retry attendee list' })); await screen.findByRole('alert')
    expect(apiClient.get.mock.calls.some(([url]) => url.includes('/attendees'))).toBe(false)
  })
})

describe('current organization settings authorization withdrawal', () => {
  it.each([401, 403])('purges private members, accounts and invitation capability after current mutation %s', async status => {
    apiClient.post.mockResolvedValueOnce({ data: { id: 5, email: 'new@example.invalid', role: 'manager', status: 'invited', invitation_token: 'private-invitation' } })
    mount(SettingsPage, '/dashboard/settings'); await screen.findByText('Private member')
    await userEvent.type(screen.getByLabelText('Teammate email'), 'new@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: 'Invite', exact: true })); await screen.findByLabelText('Invitation link')
    apiClient.delete.mockRejectedValueOnce(denied(status))
    await userEvent.click(screen.getByRole('button', { name: 'Revoke private.member@example.invalid' }))
    await screen.findByRole('alert')
    expect(screen.queryByText('Private member')).not.toBeInTheDocument()
    expect(screen.queryByText(/private_provider_requirement/)).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Invitation link')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Invite', exact: true })).not.toBeInTheDocument()
  })
  it.each(['success', 'denial'])('aborts a private parallel read and ignores its old %s after fresh role verification', async outcome => {
    const old = deferred()
    apiClient.get.mockImplementation(url => url === '/organizer/memberships' ? old.promise : url === '/organizer/connected_accounts' ? Promise.reject(denied(403)) : Promise.resolve({ data: fixture(url) }))
    mount(SettingsPage, '/dashboard/settings'); await screen.findByRole('alert')
    const oldConfig = apiClient.get.mock.calls.find(([url]) => url === '/organizer/memberships')[1]
    const verify = deferred()
    apiClient.get.mockImplementation(url => url === '/organizer/organization' ? verify.promise : Promise.resolve({ data: url === '/organizer/memberships' ? [{ ...member, name: 'Fresh member' }] : fixture(url) }))
    const count = apiClient.get.mock.calls.filter(([url]) => url === '/organizer/memberships').length
    await userEvent.click(screen.getByRole('button', { name: 'Retry organization settings' }))
    expect(apiClient.get.mock.calls.filter(([url]) => url === '/organizer/memberships')).toHaveLength(count)
    await act(async () => verify.resolve({ data: organization })); await screen.findByText('Fresh member')
    await act(async () => outcome === 'success' ? old.resolve({ data: [{ ...member, name: 'Old private member' }] }) : old.reject(denied(403)))
    expect(oldConfig.signal.aborted).toBe(true)
    expect(screen.queryByText('Old private member')).not.toBeInTheDocument()
    expect(screen.getByText('Fresh member')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
  it('retains the invitation draft for a non-permission provider outage', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 503 } })
    mount(SettingsPage, '/dashboard/settings'); await screen.findByText('Private member')
    await userEvent.type(screen.getByLabelText('Teammate email'), 'retained@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: 'Invite', exact: true })); await screen.findByRole('alert')
    expect(screen.getByLabelText('Teammate email')).toHaveValue('retained@example.invalid')
    expect(screen.getByText('Private member')).toBeInTheDocument()
  })
})

describe('refund denial preserves financial identity while withdrawing private access', () => {
  it('keeps a valid v2 operation paused when its legacy journal cannot be read', async () => {
    window.sessionStorage.setItem(journalKey, JSON.stringify(journal))
    window.sessionStorage.setItem('hafapass:pending-refund:actor-a:37', '{broken')
    mount(RefundsPage, '/dashboard/events/37/refunds')
    expect(await screen.findByRole('alert')).toHaveTextContent('Money actions are paused')
    expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(JSON.parse(window.sessionStorage.getItem(journalKey))).toEqual(journal)
    expect(window.sessionStorage.getItem('hafapass:pending-refund:actor-a:37')).toBe('{broken')
  })
  it.each([401, 403])('withdraws earlier buyer records after current stats %s without treating it as a refund verdict', async status => {
    window.sessionStorage.setItem(journalKey, JSON.stringify(journal))
    mount(RefundsPage, '/dashboard/events/37/refunds'); await screen.findByText(/Private refund buyer/)
    apiClient.get.mockImplementation(url => url.endsWith('/stats') ? Promise.reject(denied(status)) : Promise.resolve({ data: event }))
    apiClient.post.mockResolvedValueOnce({ data: { status: 'pending' } })
    await userEvent.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByRole('alert')
    expect(screen.queryByText(/Private refund buyer/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
    expect(JSON.parse(window.sessionStorage.getItem(journalKey))).toMatchObject(journal)
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })
  it.each([401, 403])('purges buyers and controls after current refund %s without changing its original journal', async status => {
    const raw = JSON.stringify(journal)
    window.sessionStorage.setItem(journalKey, raw)
    apiClient.post.mockRejectedValueOnce(denied(status))
    mount(RefundsPage, '/dashboard/events/37/refunds'); await screen.findByText(/Private refund buyer/)
    await userEvent.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByRole('alert')
    expect(screen.queryByText(/Private refund buyer/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
    expect(window.sessionStorage.getItem(journalKey)).toBe(raw)
    apiClient.get.mockImplementation(url => Promise.resolve({ data: fixture(url) }))
    await userEvent.click(screen.getByRole('button', { name: 'Retry refund access' }))
    await screen.findByRole('button', { name: 'Retry saved refund' })
    expect(screen.getByLabelText('Reason (optional)')).toHaveValue(journal.payload.reason)
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(window.sessionStorage.getItem(journalKey)).toBe(raw)
  })
  it.each(['success', 'denial'])('cannot apply an old refund %s after access retry changes the epoch', async outcome => {
    window.sessionStorage.setItem(journalKey, JSON.stringify(journal))
    let statsFailed = true
    apiClient.get.mockImplementation(url => url.endsWith('/stats') && statsFailed ? Promise.reject({ response: { status: 503 } }) : Promise.resolve({ data: fixture(url) }))
    const old = deferred(); apiClient.post.mockReturnValueOnce(old.promise)
    mount(RefundsPage, '/dashboard/events/37/refunds')
    await userEvent.click(await screen.findByRole('button', { name: 'Retry saved refund' }))
    apiClient.get.mockRejectedValueOnce(denied(403))
    await userEvent.click(screen.getByRole('button', { name: 'Retry', exact: true }))
    await screen.findByRole('button', { name: 'Retry refund access' })
    statsFailed = false
    await userEvent.click(screen.getByRole('button', { name: 'Retry refund access' }))
    await screen.findByText(/Private refund buyer/)
    await act(async () => outcome === 'success' ? old.resolve({ data: { status: 'succeeded' } }) : old.reject(denied(403)))
    expect(JSON.parse(window.sessionStorage.getItem(journalKey))).toEqual(journal)
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry saved refund' })).toBeInTheDocument()
    expect(apiClient.post.mock.calls[0][2].signal.aborted).toBe(true)
  })
})
