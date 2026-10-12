import { act, cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import Payment from './PaymentReadinessReviewDialog'
import Readiness from './PilotReadinessReviewDialog'
import Validation from './PilotValidationReviewDialog'
import Rehearsal from './EventDayRehearsalReviewDialog'
import Proof from './LiveMoneyProofReviewDialog'
import Operations from './LivePilotOperationsDialog'
import Closeout from './PilotCloseoutDialog'

vi.mock('../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn() } }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const pending = reference => ({ id: 91, actor_user_id: 7, evidence_reference: reference, evidence_digest: 'a'.repeat(64),
  controls: {}, assignments: {}, effective_at: '2026-10-01T00:00:00Z', expires_at: '2027-01-01T00:00:00Z',
  provider_approval_reference: 'restricted/provider', merchant_of_record: 'organizer', fee_tax_schedule_reference: 'restricted/fees', liability_schedule_reference: 'restricted/liability',
  expansion_decision: 'hold', signed_at: '2026-10-01T00:00:00Z', retrospective_actions: [], expansion_scope: {},
})
const cases = [
  { name: 'Payment', Component: Payment, key: null, method: 'patch', trigger: 'Review pending evidence', approve: 'Approve exact evidence', reject: 'Reject evidence' },
  { name: 'Readiness', Component: Readiness, key: 'pilot_readiness', method: 'post', trigger: 'Review readiness', approve: 'Approve exact snapshot', reject: 'Reject readiness' },
  { name: 'Validation', Component: Validation, key: 'pilot_validation', method: 'post', trigger: 'Review QA evidence', approve: 'Approve exact candidate', reject: 'Reject evidence' },
  { name: 'Rehearsal', Component: Rehearsal, key: 'event_day_rehearsal', method: 'post', trigger: 'Review rehearsal evidence', approve: 'Approve exact rehearsal', reject: 'Reject rehearsal' },
  { name: 'Proof', Component: Proof, key: 'live_money_proof', method: 'post', trigger: 'Review Gate H evidence', approve: 'Approve Gate H', reject: 'Reject' },
  { name: 'Operations', Component: Operations, key: 'live_pilot', method: 'post', trigger: 'Review Gate I pilot plan', approve: 'Approve exact Gate I plan', reject: 'Reject plan' },
  { name: 'Closeout', Component: Closeout, key: 'pilot_closeout', method: 'post', trigger: 'Review Gate J closeout', approve: 'Approve exact Gate J decision', reject: 'Reject closeout' },
]
const props = (entry, onComplete, id = 42) => entry.key ? { event: { id, title: 'Synthetic review event', status: 'published', live_money_proof_candidate: true, [entry.key]: { pending_submission: pending('Provided evidence') } }, onComplete }
  : { account: { id, provider: 'stripe', readiness_submission: pending('Provided evidence') }, onComplete }
const details = (entry, reference) => ({ event: { id: 42, title: 'Synthetic review event' }, [entry.key]: { prerequisite_ready: true, eligible: true, approved: false, pending_submission: pending(reference) } })
let clearAuth
const bind = (user = 'admin-a', session = 'session-a') => { clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: user, sessionId: session, ready: true }) }
beforeEach(() => { vi.clearAllMocks(); for (const method of ['get', 'post', 'patch']) apiClient[method].mockReset(); bind() })
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null })
const open = async entry => { await userEvent.click(screen.getByRole('button', { name: entry.trigger })); await screen.findByRole('dialog') }

describe.each(cases)('$name captured admin-dialog authority', entry => {
  it.each(['success', 'error'])('discards a late mutation %s when the same admin changes sessions', async outcome => {
    const old = deferred(), complete = vi.fn()
    if (entry.key) apiClient.get.mockResolvedValue({ data: details(entry, 'Current evidence') })
    apiClient[entry.method].mockReturnValueOnce(old.promise)
    render(<entry.Component {...props(entry, complete)} />)
    await open(entry)
    await userEvent.click(await screen.findByRole('button', { name: entry.approve }))
    const config = apiClient[entry.method].mock.calls[0][2]
    await act(async () => bind('admin-a', 'session-b'))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await open(entry)
    const input = screen.getByRole('textbox', { name: /Rejection|correction/i })
    await userEvent.type(input, 'Fresh-session reason')
    expect(input).toHaveFocus()
    await act(async () => outcome === 'success' ? old.resolve({ data: {} }) : old.reject(new Error('Old-session failure')))
    expect(input).toHaveValue('Fresh-session reason')
    expect(input).toHaveFocus()
    expect(screen.getByRole('button', { name: entry.approve })).toBeEnabled()
    expect(complete).not.toHaveBeenCalled()
    expect(config.authContext.sessionId).toBe('session-a'); expect(config.signal.aborted).toBe(true)
    expect(apiClient[entry.method]).toHaveBeenCalledTimes(1)
  })

  it('retains the reason and original server error when a current decision is rejected', async () => {
    if (entry.key) apiClient.get.mockResolvedValue({ data: details(entry, 'Current evidence') })
    apiClient.post.mockRejectedValueOnce({ response: { status: 403, data: { error: 'Independent administrator required' } } })
    render(<entry.Component {...props(entry, vi.fn())} />)
    await open(entry)
    const input = screen.getByRole('textbox', { name: /Rejection|correction/i })
    await userEvent.type(input, 'Keep this correction')
    await userEvent.click(screen.getByRole('button', { name: entry.reject }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Independent administrator required')
    expect(input).toHaveValue('Keep this correction')
    expect(screen.getByRole('button', { name: entry.reject })).toBeEnabled()
  })

  it('closes private evidence after an explicit current administrator denial without borrowing a later opening', async () => {
    if (entry.key) apiClient.get.mockResolvedValue({ data: details(entry, 'Private evidence to purge') })
    apiClient[entry.method].mockRejectedValueOnce({ response: { status: 403, data: { error: 'Admin access required' } } })
    render(<entry.Component {...props(entry, vi.fn())} />)
    await open(entry)
    await userEvent.click(await screen.findByRole('button', { name: entry.approve }))
    expect(await screen.findByRole('button', { name: 'Retry administrator access' })).toBeEnabled()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText('Private evidence to purge', { exact: false })).not.toBeInTheDocument()
    expect(apiClient[entry.method]).toHaveBeenCalledTimes(1)
  })

  if (entry.key) it('never exposes cached parent evidence when an opening read loses administrator access', async () => {
    apiClient.get.mockRejectedValueOnce({ response: { status: 403, data: { error: 'Admin access required' } } })
    render(<entry.Component {...props(entry, vi.fn())} />)
    await userEvent.click(screen.getByRole('button', { name: entry.trigger }))
    expect(await screen.findByRole('button', { name: 'Retry administrator access' })).toBeEnabled()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText('Provided evidence', { exact: false })).not.toBeInTheDocument()
  })

  if (entry.key) it('discards a closed dialog read even after the same account opens it again', async () => {
    const old = deferred()
    apiClient.get.mockReturnValueOnce(old.promise).mockResolvedValue({ data: details(entry, 'Fresh opening evidence') })
    render(<entry.Component {...props(entry, vi.fn())} />)
    await open(entry)
    const config = apiClient.get.mock.calls[0][1]
    await userEvent.click(screen.getByRole('button', { name: /^Close /i }))
    await open(entry)
    expect(await screen.findByText('Fresh opening evidence', { exact: false })).toBeInTheDocument()
    await act(async () => old.resolve({ data: details(entry, 'Stale opening evidence') }))
    expect(screen.queryByText('Stale opening evidence', { exact: false })).not.toBeInTheDocument()
    expect(config.signal.aborted).toBe(true)
  })
})
