import { useState } from 'react'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes, useParams } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../api/client'
import TicketTypeCRUD from './TicketTypeCRUD'
import PricingTiersCRUD from './PricingTiersCRUD'
import { useOrganizerIdentity, useOrganizerRequests } from '../hooks/useOrganizerContext'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() } }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const ticket = id => ({ id: 7, name: `Ticket ${id}`, price_cents: 1200, quantity_available: 20 })
const tier = id => ({ id: 9, name: `Tier ${id}`, price_cents: 800, position: 0, tier_type: 'quantity_based', quantity_limit: 10 })
let clearAuth, refresh
const bind = (owner = 'actor-a', session = 'one', getter = () => Promise.resolve('synthetic-token')) => {
  window.localStorage.setItem('hafapass_scanner_user_id', owner)
  clearAuth = setAuthTokenGetter(getter, { userId: owner, sessionId: session, ready: true })
}
function Page({ kind, parent = false }) {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const { beginRequest } = useOrganizerRequests(identity, `/inventory/${id}`)
  return kind === 'ticket' ? <TicketTypeCRUD eventId={id} ticketTypes={[ticket(id)]} remainingCapacity={30} onRefresh={refresh} beginRequest={parent ? beginRequest : undefined} />
    : <PricingTiersCRUD eventId={id} ticketTypeId={7} basePriceCents={5000} salesEndAt="2027-05-02T14:00:00Z" onRefresh={refresh} beginRequest={parent ? beginRequest : undefined} />
}
const mount = (kind, parent = false) => render(<MemoryRouter initialEntries={['/inventory/11']}>
  <Link to="/inventory/11">Open Alpha</Link><Link to="/inventory/22">Open Beta</Link>
  <Routes><Route path="/inventory/:id" element={<Page kind={kind} parent={parent} />} /></Routes>
</MemoryRouter>)
const prepare = async kind => {
  if (kind === 'ticket') {
    await userEvent.click(screen.getByRole('button', { name: 'Edit Ticket 11' }))
    await userEvent.clear(screen.getByLabelText(/^Name/)); await userEvent.type(screen.getByLabelText(/^Name/), 'Private ticket draft')
  } else {
    await userEvent.click(await screen.findByRole('button', { name: 'Edit pricing tier Tier 11' }))
    await userEvent.clear(screen.getByLabelText(/^Name/)); await userEvent.type(screen.getByLabelText(/^Name/), 'Private tier draft')
  }
}
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '1'); bind()
  refresh = vi.fn()
  for (const method of ['get', 'post', 'put', 'patch', 'delete']) apiClient[method].mockReset()
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/pricing_tiers') ? [tier(path.split('/')[3])] : {} }))
  apiClient.post.mockResolvedValue({ data: {} }); apiClient.put.mockResolvedValue({ data: {} }); apiClient.delete.mockResolvedValue({})
})
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null; vi.restoreAllMocks() })

for (const kind of ['ticket', 'tier']) describe(`${kind} inventory ownership`, () => {
  it.each([false, true])('pins the write to captured actor/org with parent binding %s', async parent => {
    mount(kind, parent)
    await prepare(kind)
    const identity = getApiAuthContext()
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    await waitFor(() => expect(apiClient.put).toHaveBeenCalledTimes(1))
    const [path, payload, config] = apiClient.put.mock.calls[0]
    expect(path).toContain('/organizer/events/11/ticket_types/7')
    expect(payload.name).toBe(kind === 'ticket' ? 'Private ticket draft' : 'Private tier draft')
    expect(config.authContext).toBe(identity)
    expect(config.organizationId).toBe('1')
    expect(config.signal).toBeInstanceOf(AbortSignal)
    await waitFor(() => expect(refresh).toHaveBeenCalledTimes(1))
  })

  it.each(['account', 'session', 'organization'])('clears private forms and ignores an earlier write after %s replacement', async replacement => {
    const old = deferred()
    apiClient.put.mockReturnValueOnce(old.promise)
    mount(kind)
    await prepare(kind)
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    const config = apiClient.put.mock.calls[0][2]
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'two')
    })
    expect(screen.queryByDisplayValue(/Private .* draft/)).not.toBeInTheDocument()
    await act(async () => old.resolve({ data: {} }))
    expect(config.signal.aborted).toBe(true)
    expect(refresh).not.toHaveBeenCalled()
  })

  it.each(['success', 'error'])('cannot revive the old event form on delayed write %s', async outcome => {
    const old = deferred()
    apiClient.put.mockReturnValueOnce(old.promise)
    mount(kind)
    await prepare(kind)
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    if (kind === 'ticket') await screen.findByText('Ticket 22')
    else await screen.findByText('Tier 22')
    await act(async () => outcome === 'success' ? old.resolve({ data: {} }) : old.reject(new Error('Old failure')))
    expect(screen.queryByDisplayValue(/Private .* draft/)).not.toBeInTheDocument()
    expect(screen.queryByText(/change may have completed/)).not.toBeInTheDocument()
    expect(refresh).not.toHaveBeenCalled()
  })

  it('retains the draft on a definitive rejection without replaying it during read refresh', async () => {
    apiClient.put.mockRejectedValueOnce({ response: { status: 422, data: { errors: ['Synthetic inventory validation failed'] } } })
    mount(kind)
    await prepare(kind)
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    await screen.findByText('Synthetic inventory validation failed')
    expect(screen.getByLabelText(/^Name/)).toHaveValue(kind === 'ticket' ? 'Private ticket draft' : 'Private tier draft')
    expect(apiClient.put).toHaveBeenCalledTimes(1)
    expect(refresh).not.toHaveBeenCalled()
  })

  it('retains a lost-response pause across remount without repeating the mutation', async () => {
    apiClient.put.mockRejectedValueOnce(new Error('Synthetic response loss'))
    const first = mount(kind)
    await prepare(kind)
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    await screen.findByRole('region', { name: kind === 'ticket' ? 'Unconfirmed ticket change' : 'Unconfirmed pricing change' })
    first.unmount(); mount(kind)
    await screen.findByRole('region', { name: kind === 'ticket' ? 'Unconfirmed ticket change' : 'Unconfirmed pricing change' })
    expect(apiClient.put).toHaveBeenCalledTimes(1)
  })

  it('fails closed for a malformed saved recovery marker', async () => {
    const key = kind === 'ticket' ? 'hafapass:pending-ticket-types:actor-a:1:11' : 'hafapass:pending-pricing-tiers:actor-a:1:11:7'
    window.sessionStorage.setItem(key, '{broken-record')
    mount(kind)
    await screen.findByRole('region', { name: kind === 'ticket' ? 'Unconfirmed ticket change' : 'Unconfirmed pricing change' })
    expect(screen.getByRole('button', { name: kind === 'ticket' ? 'Edit Ticket 11' : 'Edit pricing tier Tier 11' })).toBeDisabled()
    expect(apiClient.put).not.toHaveBeenCalled()
  })

  it('suppresses transport after context changes during queued token acquisition', async () => {
    const actual = await vi.importActual('../api/client')
    const token = deferred(), adapter = vi.fn()
    const previousAdapter = actual.default.defaults.adapter
    actual.default.defaults.adapter = adapter
    bind('actor-a', 'one', () => token.promise)
    apiClient.put.mockImplementation((...args) => actual.default.put(...args))
    try {
      mount(kind)
      await prepare(kind)
      await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
      await act(async () => bind('actor-b', 'two'))
      await act(async () => token.resolve('original-synthetic-token'))
      expect(adapter).not.toHaveBeenCalled()
      expect(refresh).not.toHaveBeenCalled()
    } finally { actual.default.defaults.adapter = previousAdapter }
  })
})

it('aborts a pricing child token request when the child closes while its parent stays mounted', async () => {
  const actual = await vi.importActual('../api/client')
  const token = deferred(), adapter = vi.fn()
  const previousAdapter = actual.default.defaults.adapter
  actual.default.defaults.adapter = adapter
  bind('actor-a', 'one', () => token.promise)
  apiClient.put.mockImplementation((...args) => actual.default.put(...args))
  function Parent() {
    const identity = useOrganizerIdentity()
    const { beginRequest } = useOrganizerRequests(identity, '/inventory/11')
    const [visible, setVisible] = useState(true)
    return <><button type="button" onClick={() => setVisible(false)}>Close child</button>{visible && <PricingTiersCRUD eventId={11} ticketTypeId={7} beginRequest={beginRequest} />}</>
  }
  try {
    render(<MemoryRouter initialEntries={['/inventory/11']}><Parent /></MemoryRouter>)
    await prepare('tier')
    await userEvent.click(screen.getByRole('button', { name: 'Update', exact: true }))
    await userEvent.click(screen.getByRole('button', { name: 'Close child' }))
    await act(async () => token.resolve('same-actor-synthetic-token'))
    expect(adapter).not.toHaveBeenCalled()
  } finally { actual.default.defaults.adapter = previousAdapter }
})

it('discards earlier pricing loads when selecting another ticket type', async () => {
  const old = deferred()
  apiClient.get.mockImplementation(path => path.includes('/ticket_types/7/') ? old.promise : Promise.resolve({ data: [tier('new')] }))
  const first = render(<MemoryRouter><PricingTiersCRUD eventId={11} ticketTypeId={7} /></MemoryRouter>)
  await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
  first.rerender(<MemoryRouter><PricingTiersCRUD eventId={11} ticketTypeId={8} /></MemoryRouter>)
  await screen.findByText('Tier new')
  await act(async () => old.resolve({ data: [tier('old-private')] }))
  expect(screen.queryByText('Tier old-private')).not.toBeInTheDocument()
})


it('orders price windows, shows the gap and sales close, and chains the exact previous end', async () => {
  const end = '2027-05-01T13:59:01.445600Z'
  apiClient.get.mockResolvedValue({ data: [
    { id: 12, name: 'Regular', price_cents: 3500, tier_type: 'time_based', starts_at: '2027-05-01T10:00:00Z', ends_at: end },
    { id: 11, name: 'Early Bird', price_cents: 2000, tier_type: 'time_based', ends_at: '2027-05-01T09:59:00Z' },
  ] })
  mount('tier')
  await screen.findByRole('heading', { name: 'Pricing Schedule' })
  expect(screen.getAllByRole('button', { name: /Edit pricing tier/ }).map(button => button.getAttribute('aria-label')))
    .toEqual(['Edit pricing tier Early Bird', 'Edit pricing tier Regular'])
  expect(screen.getByText(/Gap from/)).toHaveTextContent('The base price of $50.00 applies')
  expect(screen.getByText(/Sales close/)).toHaveTextContent('Guam time (ChST)')
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: /Add next price window/ }))
  expect(screen.getByRole('radio', { name: 'Date & Time window' })).toBeChecked()
  expect(screen.getByText(/Dates and times use/)).toHaveTextContent('Guam time (ChST, UTC+10)')
  expect(screen.getByLabelText('Starts at date')).toHaveValue('2027-05-01')
  expect(screen.getByLabelText('Starts at time')).toHaveValue('23:59:01')
  await user.type(screen.getByLabelText(/^Name/), 'Last chance')
  await user.click(screen.getByRole('button', { name: 'Add price', exact: true }))
  expect(apiClient.post.mock.calls[0][1]).toMatchObject({ starts_at: end, ends_at: null, tier_type: 'time_based' })
})

it('moves quantity caps up and down and reads back their saved order', async () => {
  const first = { ...tier('first'), id: 11, name: 'First cap' }
  const second = { ...tier('second'), id: 12, name: 'Second cap' }
  apiClient.get.mockResolvedValueOnce({ data: [first, second] }).mockResolvedValueOnce({ data: [second, first] })
    .mockResolvedValueOnce({ data: [first, second] })
  apiClient.patch.mockResolvedValue({})
  mount('tier')
  expect(await screen.findByRole('button', { name: 'Move First cap up' })).toBeDisabled()
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: 'Move Second cap up' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Move Second cap down' })).toBeEnabled())
  expect(apiClient.patch.mock.calls[0].slice(0, 2)).toEqual(['/organizer/events/11/ticket_types/7/pricing_tiers/12/move', { direction: 'up' }])
  await user.click(screen.getByRole('button', { name: 'Move Second cap down' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Move Second cap down' })).toBeDisabled())
  expect(apiClient.patch.mock.calls[1][1]).toEqual({ direction: 'down' })
})
