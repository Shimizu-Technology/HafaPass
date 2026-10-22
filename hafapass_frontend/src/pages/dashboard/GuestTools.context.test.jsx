import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import GuestListPage from './GuestListPage'
import PromoCodesPage from './PromoCodesPage'
import WaitlistPage from './WaitlistPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: {
  get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn(),
} }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const tools = [
  { path: 'guest-list', endpoint: 'guest_list', Component: GuestListPage, title: 'Guest List', retry: 'Retry guest list',
    permission: 'manage_attendees', dialogButton: 'Redeem', row: owner => ({ id: 5, guest_name: `${owner} private guest`, guest_email: `${owner}@example.invalid`, redeemed: false, quantity: 1, ticket_type: { id: 8, name: 'Admission' } }),
    result: rows => ({ guest_list: rows }), button: 'Redeem', confirmation: 'Redeem tickets', notice: 'Guest tickets created.', method: 'post', tail: '/5/redeem' },
  { path: 'promo-codes', endpoint: 'promo_codes', Component: PromoCodesPage, title: 'Promo Codes', retry: 'Retry promo codes',
    permission: 'manage_marketing', dialogButton: /Delete promo code/, row: owner => ({ id: 5, code: `${owner} private code`, active: true, discount_type: 'percentage', discount_value: 20, current_uses: 0 }),
    result: rows => rows, button: /Deactivate promo code/, notice: 'Promo code updated.', method: 'patch', tail: '/5' },
  { path: 'waitlist', endpoint: 'waitlist', Component: WaitlistPage, title: 'Waitlist', retry: 'Retry waitlist',
    permission: 'manage_attendees', dialogButton: /Notify actor-a private attendee/, row: owner => ({ id: 5, name: `${owner} private attendee`, email: `${owner}@example.invalid`, status: 'waiting', position: 1, quantity: 1, created_at: '2026-11-20T09:00:00Z' }),
    result: rows => ({ waitlist: rows, stats: { total_waiting: rows.length } }), button: /Notify actor-a private attendee/, confirmation: 'Send notification', notice: 'Notification request recorded. Delivery is handled separately.', method: 'post', tail: '/5/notify' },
]
const event = (id, organizationId = 1) => ({ id, organization_id: organizationId, title: `Synthetic event ${id}`, status: 'draft',
  permissions: { manage_attendees: true, manage_marketing: true }, ticket_types: [{ id: 8, name: 'Admission' }] })
let clearAuth, activeTool, rows
const bind = (owner, session = 'one', getter = () => Promise.resolve('synthetic-token')) => {
  window.localStorage.setItem('hafapass_scanner_user_id', owner)
  clearAuth = setAuthTokenGetter(getter, { userId: owner, sessionId: session, ready: true })
}
const Location = () => <p data-testid="tool-location">{useLocation().pathname}</p>
const mount = tool => render(<MemoryRouter initialEntries={[`/dashboard/events/11/${tool.path}`]}>
  <Link to={`/dashboard/events/11/${tool.path}`}>Open Alpha</Link><Link to={`/dashboard/events/22/${tool.path}`}>Open Beta</Link><Location />
  <Routes><Route path={`/dashboard/events/:id/${tool.path}`} element={<tool.Component />} /></Routes>
</MemoryRouter>)
const load = (path, config = {}) => {
  if (path === '/organizer/organizations') return Promise.resolve({ data: [{ id: Number(config.organizationId || 1), name: 'Synthetic organizer' }] })
  const id = Number(path.split('/')[3])
  if (path.endsWith(`/${activeTool.endpoint}`)) return Promise.resolve({ data: activeTool.result([activeTool.row(rows[id])]) })
  return Promise.resolve({ data: event(id, Number(config.organizationId || 1)) })
}
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '1')
  bind('actor-a')
  rows = { 11: 'actor-a', 22: 'Beta' }
  for (const method of ['get', 'post', 'patch', 'delete']) apiClient[method].mockReset()
  apiClient.get.mockImplementation(load)
  apiClient.post.mockResolvedValue({ data: {} }); apiClient.patch.mockResolvedValue({ data: {} }); apiClient.delete.mockResolvedValue({})
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null; vi.restoreAllMocks() })

for (const tool of tools) describe(`${tool.title} context ownership`, () => {
  beforeEach(() => { activeTool = tool })
  it('keeps mutations paused when a stored recovery record cannot be parsed', async () => {
    const key = `hafapass:pending-${tool.path === 'guest-list' ? 'guest-list' : tool.path === 'promo-codes' ? 'promo-codes' : 'waitlist'}:actor-a:1:11`
    window.sessionStorage.setItem(key, '{broken')
    mount(tool)
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    expect(screen.getByRole('button', { name: tool.button })).toBeDisabled()
    expect(window.sessionStorage.getItem(key)).toBe('{broken')
    expect(apiClient[tool.method]).not.toHaveBeenCalled()
  })

  it.each(['success', 'error'])('does not revive an old load %s after changing event', async outcome => {
    const old = deferred()
    apiClient.get.mockImplementation((path, config) => path === `/organizer/events/11/${tool.endpoint}` ? old.promise : load(path, config))
    mount(tool)
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await screen.findByText(tool.row('Beta').guest_name || tool.row('Beta').code || tool.row('Beta').name)
    await act(async () => outcome === 'success' ? old.resolve({ data: tool.result([tool.row('old-private')]) }) : old.reject(new Error('Old failure')))
    expect(screen.queryByText(/old-private/)).not.toBeInTheDocument()
    expect(screen.queryByText('The guest list could not be loaded.')).not.toBeInTheDocument()
    const read = apiClient.get.mock.calls.find(([path]) => path === `/organizer/events/11/${tool.endpoint}`)
    expect(read[1].organizationId).toBe('1')
    expect(read[1].signal.aborted).toBe(true)
  })

  it.each(['session', 'account', 'organization'])('removes old private records across a %s replacement before its next load completes', async replacement => {
    mount(tool)
    const oldName = tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name
    await screen.findByText(oldName)
    const fresh = deferred()
    apiClient.get.mockImplementation((path, config) => path.endsWith(`/${tool.endpoint}`) ? fresh.promise : load(path, config))
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'two')
    })
    expect(screen.queryByText(oldName)).not.toBeInTheDocument()
    await act(async () => fresh.resolve({ data: tool.result([tool.row('current-private')]) }))
    expect(await screen.findByText(tool.row('current-private').guest_name || tool.row('current-private').code || tool.row('current-private').name)).toBeInTheDocument()
  })

  it.each(['success', 'error'])('ignores an old mutation %s and preserves the new event result', async outcome => {
    const old = deferred()
    apiClient[tool.method].mockReturnValueOnce(old.promise)
    mount(tool)
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    await userEvent.click(screen.getByRole('button', { name: tool.button }))
    if (tool.confirmation) await userEvent.click(screen.getByRole('button', { name: tool.confirmation }))
    const write = apiClient[tool.method].mock.calls[0]
    const config = write.at(-1)
    expect(write[0]).toBe(`/organizer/events/11/${tool.endpoint}${tool.tail}`)
    expect(config.organizationId).toBe('1')
    expect(config.authContext).toBe(getApiAuthContext())
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await screen.findByText(tool.row('Beta').guest_name || tool.row('Beta').code || tool.row('Beta').name)
    await act(async () => outcome === 'success' ? old.resolve({ data: {} }) : old.reject(new Error('Old mutation failure')))
    expect(screen.queryByText(tool.notice)).not.toBeInTheDocument()
    expect(screen.queryByText(/The response was interrupted/)).not.toBeInTheDocument()
    expect(screen.getByTestId('tool-location')).toHaveTextContent(`/dashboard/events/22/${tool.path}`)
    expect(config.signal.aborted).toBe(true)
  })

  it.each(['session', 'account', 'organization'])('withdraws an earlier write across a %s replacement', async replacement => {
    const old = deferred()
    apiClient[tool.method].mockReturnValueOnce(old.promise)
    mount(tool)
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    await userEvent.click(screen.getByRole('button', { name: tool.button }))
    if (tool.confirmation) await userEvent.click(screen.getByRole('button', { name: tool.confirmation }))
    const originalConfig = apiClient[tool.method].mock.calls[0].at(-1)
    rows[11] = 'current-private'
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'two')
    })
    await screen.findByText(tool.row('current-private').guest_name || tool.row('current-private').code || tool.row('current-private').name)
    await act(async () => old.resolve({ data: {} }))
    expect(originalConfig.signal.aborted).toBe(true)
    expect(screen.queryByText(tool.notice)).not.toBeInTheDocument()
    expect(screen.queryByText(/actor-a private/)).not.toBeInTheDocument()
    expect(apiClient[tool.method]).toHaveBeenCalledTimes(1)
    if (replacement !== 'session') expect(screen.queryByRole('region', { name: 'Unconfirmed operation' })).not.toBeInTheDocument()
    const stored = Object.values(window.sessionStorage).join(' ')
    expect(stored).not.toContain('actor-a private')
  })

  it.each(['session', 'account', 'organization'])('withdraws an open private confirmation across a %s replacement', async replacement => {
    mount(tool)
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    await userEvent.click(screen.getByRole('button', { name: tool.dialogButton }))
    expect(screen.getByRole('dialog', { name: 'Confirm action' })).toBeInTheDocument()
    const nextLoad = deferred()
    apiClient.get.mockImplementation((path, config) => path.endsWith(`/${tool.endpoint}`) ? nextLoad.promise : load(path, config))
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'two')
    })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText(/actor-a private/)).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled(); expect(apiClient.patch).not.toHaveBeenCalled(); expect(apiClient.delete).not.toHaveBeenCalled()
    await act(async () => nextLoad.resolve({ data: tool.result([]) }))
  })

  it.each(['session', 'account', 'organization'])('ignores a previously pending load after a %s replacement', async replacement => {
    const old = deferred()
    let original = true
    apiClient.get.mockImplementation((path, config) => {
      if (path.endsWith(`/${tool.endpoint}`)) {
        if (original) return old.promise
        return Promise.resolve({ data: tool.result([tool.row('new-private')]) })
      }
      return load(path, config)
    })
    mount(tool)
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    original = false
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'two')
    })
    await screen.findByText(tool.row('new-private').guest_name || tool.row('new-private').code || tool.row('new-private').name)
    await act(async () => old.resolve({ data: tool.result([tool.row('old-private')]) }))
    expect(screen.queryByText(/old-private/)).not.toBeInTheDocument()
    expect(screen.getByText(tool.row('new-private').guest_name || tool.row('new-private').code || tool.row('new-private').name)).toBeInTheDocument()
  })

  it('retries only the failed read and does not turn a load error into a false empty state', async () => {
    let failed = true
    apiClient.get.mockImplementation((path, config) => path.endsWith(`/${tool.endpoint}`) && failed ? Promise.reject(new Error('Synthetic outage')) : load(path, config))
    mount(tool)
    await screen.findByRole('alert')
    expect(screen.queryByText(/No guests added yet|No promo codes yet|No waitlist entries found/)).not.toBeInTheDocument()
    failed = false
    await userEvent.click(screen.getByRole('button', { name: tool.retry }))
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    expect(apiClient.post).not.toHaveBeenCalled(); expect(apiClient.patch).not.toHaveBeenCalled(); expect(apiClient.delete).not.toHaveBeenCalled()
  })

  it('keeps an uncertain mutation paused across refresh and remount without resending it', async () => {
    apiClient[tool.method].mockRejectedValueOnce(new Error('Synthetic lost response'))
    const first = mount(tool)
    await screen.findByText(tool.row('actor-a').guest_name || tool.row('actor-a').code || tool.row('actor-a').name)
    await userEvent.click(screen.getByRole('button', { name: tool.button }))
    if (tool.confirmation) await userEvent.click(screen.getByRole('button', { name: tool.confirmation }))
    await screen.findByRole('region', { name: 'Unconfirmed operation' })
    const reads = apiClient.get.mock.calls.length
    await userEvent.click(screen.getByRole('button', { name: 'Refresh latest list' }))
    await waitFor(() => expect(apiClient.get.mock.calls.length).toBeGreaterThan(reads))
    await waitFor(() => expect(screen.getByRole('button', { name: tool.button })).toBeDisabled())
    first.unmount(); mount(tool)
    await screen.findByRole('region', { name: 'Unconfirmed operation' })
    expect(screen.getByRole('button', { name: tool.button })).toBeDisabled()
    expect(apiClient[tool.method]).toHaveBeenCalledTimes(1)
  })

  it('does not offer mutations to a role without the required permission', async () => {
    apiClient.get.mockImplementation((path, config) => /^\/organizer\/events\/\d+$/.test(path)
      ? Promise.resolve({ data: { ...event(Number(path.split('/').at(-1))), permissions: {} } }) : load(path, config))
    mount(tool)
    await screen.findByText('Your event access does not include this tool.')
    expect(screen.queryByRole('button', { name: tool.button })).not.toBeInTheDocument()
    expect(apiClient[tool.method]).not.toHaveBeenCalled()
  })
})

describe('draft retention and current waitlist view', () => {
  it('allows clear-and-type guest quantity and sends the valid numeric quantity with scoped ownership', async () => {
    activeTool = tools[0]
    mount(activeTool)
    await screen.findByRole('heading', { name: 'Guest List', level: 2 })
    await userEvent.click(screen.getByRole('button', { name: 'Add Guest' }))
    const form = screen.getByRole('heading', { name: 'Add to Guest List' }).closest('form')
    await userEvent.type(within(form).getByRole('textbox', { name: 'Name' }), 'Synthetic guest')
    const quantity = within(form).getByRole('spinbutton', { name: 'Quantity' })
    await userEvent.clear(quantity)
    expect(quantity).toHaveValue(null)
    await userEvent.type(quantity, '3')
    expect(quantity).toHaveValue(3)
    expect(quantity).toHaveAttribute('aria-invalid', 'false')
    await userEvent.click(within(form).getByRole('button', { name: 'Add Guest' }))
    await screen.findByText('Guest added. Any notification is handled separately.')
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/11/guest_list', {
      guest_name: 'Synthetic guest', guest_email: '', guest_phone: '', notes: '', quantity: 3, ticket_type_id: 8,
    }, expect.objectContaining({ organizationId: '1', authContext: getApiAuthContext() }))
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it.each(['', '0', '11', '1.5'])('blocks invalid guest quantity %j at both the submit control and handler', async value => {
    activeTool = tools[0]
    mount(activeTool)
    await screen.findByRole('heading', { name: 'Guest List', level: 2 })
    await userEvent.click(screen.getByRole('button', { name: 'Add Guest' }))
    const form = screen.getByRole('heading', { name: 'Add to Guest List' }).closest('form')
    await userEvent.type(within(form).getByRole('textbox', { name: 'Name' }), 'Retained guest draft')
    const quantity = within(form).getByRole('spinbutton', { name: 'Quantity' })
    expect(quantity).toBeRequired()
    expect(quantity).toHaveAttribute('min', '1')
    expect(quantity).toHaveAttribute('max', '10')
    await userEvent.clear(quantity)
    if (value) await userEvent.type(quantity, value)
    expect(quantity).toHaveValue(value ? Number(value) : null)
    expect(quantity).toHaveAttribute('aria-invalid', 'true')
    expect(quantity).toHaveAccessibleDescription('Enter a whole number from 1 to 10.')
    const addGuest = within(form).getByRole('button', { name: 'Add Guest' })
    expect(addGuest).toBeDisabled()
    await userEvent.click(addGuest)
    fireEvent.submit(form)
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(within(form).getByRole('textbox', { name: 'Name' })).toHaveValue('Retained guest draft')
    await userEvent.clear(quantity)
    await userEvent.type(quantity, '10')
    expect(quantity).toHaveValue(10)
    expect(addGuest).toBeEnabled()
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it.each(['guest-list', 'promo-codes'])('retains the %s draft through validation failure and a list retry', async path => {
    activeTool = tools.find(tool => tool.path === path)
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { errors: ['Synthetic validation rejected'] } } })
    mount(activeTool)
    await screen.findByRole('heading', { name: activeTool.title, level: 2 })
    await userEvent.click(screen.getByRole('button', { name: path === 'guest-list' ? 'Add Guest' : 'New Code' }))
    const form = screen.getByRole('heading', { name: path === 'guest-list' ? 'Add to Guest List' : 'Create Promo Code' }).closest('form')
    const field = within(form).getByLabelText(path === 'guest-list' ? 'Name' : 'Code')
    await userEvent.type(field, path === 'guest-list' ? 'Unsaved guest draft' : 'DRAFT20')
    if (path === 'promo-codes') await userEvent.type(within(form).getByLabelText('Discount (%)'), '20')
    await userEvent.click(within(form).getByRole('button', { name: path === 'guest-list' ? 'Add Guest' : 'Create Code' }))
    await screen.findByText('Synthetic validation rejected')
    expect(field).toHaveValue(path === 'guest-list' ? 'Unsaved guest draft' : 'DRAFT20')
    await userEvent.click(screen.getByRole('button', { name: 'Check latest list' }))
    await waitFor(() => expect(within(form).getByRole('button', { name: path === 'guest-list' ? 'Add Guest' : 'Create Code' })).toBeEnabled())
    expect(field).toHaveValue(path === 'guest-list' ? 'Unsaved guest draft' : 'DRAFT20')
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it.each(['guest-list', 'promo-codes'])('clears private draft fields across an account replacement on %s', async path => {
    activeTool = tools.find(tool => tool.path === path)
    mount(activeTool)
    await screen.findByRole('heading', { name: activeTool.title, level: 2 })
    await userEvent.click(screen.getByRole('button', { name: path === 'guest-list' ? 'Add Guest' : 'New Code' }))
    const label = path === 'guest-list' ? 'Name' : 'Code'
    await userEvent.type(screen.getByLabelText(label), 'PRIVATE-DRAFT')
    await act(async () => bind('actor-b', 'two'))
    expect(screen.queryByDisplayValue('PRIVATE-DRAFT')).not.toBeInTheDocument()
    await screen.findByRole('heading', { name: activeTool.title, level: 2 })
    await userEvent.click(screen.getByRole('button', { name: path === 'guest-list' ? 'Add Guest' : 'New Code' }))
    expect(screen.getByLabelText(label)).toHaveValue('')
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('refreshes the currently selected waitlist filter after an earlier mutation finishes', async () => {
    activeTool = tools[2]
    const write = deferred()
    apiClient.post.mockReturnValueOnce(write.promise)
    const filters = []
    apiClient.get.mockImplementation((path, config) => {
      if (path.endsWith('/waitlist')) {
        filters.push(config.params.status || '')
        return Promise.resolve({ data: activeTool.result([{ ...activeTool.row(config.params.status || 'actor-a'), status: config.params.status || 'waiting' }]) })
      }
      return load(path, config)
    })
    mount(activeTool)
    await screen.findByText('actor-a private attendee')
    expect(screen.getByRole('button', { name: 'All', pressed: true })).toBeInTheDocument()
    const entries = screen.getByRole('region', { name: 'Waitlist entries' })
    entries.focus()
    expect(entries).toHaveFocus()
    await userEvent.click(screen.getByRole('button', { name: /Notify actor-a private attendee/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Send notification' }))
    await userEvent.click(screen.getByRole('button', { name: /^Notified/ }))
    await screen.findByText('notified private attendee')
    expect(screen.getByRole('button', { name: /^Notified/, pressed: true })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'All', pressed: false })).toBeInTheDocument()
    await act(async () => write.resolve({ data: {} }))
    await screen.findByText(activeTool.notice)
    await waitFor(() => expect(screen.queryByText('Updating the list…')).not.toBeInTheDocument())
    expect(filters.at(-1)).toBe('notified')
    expect(screen.getByText('notified private attendee')).toBeInTheDocument()
    expect(screen.queryByText('actor-a private attendee')).not.toBeInTheDocument()
  })

  it('uses the labelled notify count only after confirmation and retains scoped request ownership', async () => {
    activeTool = tools[2]
    apiClient.post.mockResolvedValueOnce({ data: { count: 3 } })
    mount(activeTool)
    await screen.findByText('actor-a private attendee')
    const count = screen.getByRole('spinbutton', { name: 'People to notify' })
    await userEvent.clear(count)
    await userEvent.type(count, '3')
    expect(count).toHaveValue(3)
    await userEvent.click(screen.getByRole('button', { name: 'Notify Next' }))
    const dialog = screen.getByRole('dialog', { name: 'Confirm action' })
    expect(within(dialog).getByText('Notify the next 3 people on the waitlist?')).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Send next notifications' }))
    await screen.findByText('Notification requests recorded for 3 people. Delivery is handled separately.')
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/11/waitlist/notify_next', { count: 3 }, expect.objectContaining({ organizationId: '1', authContext: getApiAuthContext() }))
  })

  it.each(['', '0', '51', '1.5'])('blocks notify-next for invalid count %j while keeping the draft editable', async value => {
    activeTool = tools[2]
    mount(activeTool)
    await screen.findByText('actor-a private attendee')
    const count = screen.getByRole('spinbutton', { name: 'People to notify' })
    await userEvent.clear(count)
    if (value) await userEvent.type(count, value)
    expect(count).toHaveValue(value ? Number(value) : null)
    expect(count).toHaveAttribute('aria-invalid', 'true')
    expect(count).toHaveAccessibleDescription('Enter a whole number from 1 to 50.')
    const notifyNext = screen.getByRole('button', { name: 'Notify Next' })
    expect(notifyNext).toBeDisabled()
    await userEvent.click(notifyNext)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
    await userEvent.clear(count)
    await userEvent.type(count, '50')
    expect(count).toHaveValue(50)
    expect(count).toHaveAttribute('aria-invalid', 'false')
    expect(notifyNext).toBeEnabled()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
})

describe('waitlist readable statuses', () => {
  it('labels filters and rows in plain words with the counts the API reports', async () => {
    activeTool = { ...tools[2], result: rows => ({ waitlist: rows, stats: { total_waiting: 3, total_notified: 2, total_expired: 0, total_converted: 1 } }) }
    mount(activeTool)
    await screen.findByText('actor-a private attendee')
    const filters = screen.getByRole('group', { name: 'Filter by status' })
    expect(within(filters).getAllByRole('button').map(button => button.textContent)).toEqual(['All', 'Waiting (3)', 'Notified (2)', 'Expired (0)', 'Converted (1)'])
    for (const name of ['Waiting (3)', 'Notified (2)', 'Expired (0)', 'Converted (1)']) expect(screen.getByRole('button', { name })).toBeInTheDocument()
    expect(within(screen.getByRole('region', { name: 'Waitlist entries' })).getByText('Waiting')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Notify Next' })).toBeEnabled()
  })

  it('disables notify-next with a reason when nobody is waiting', async () => {
    activeTool = { ...tools[2], result: () => ({ waitlist: [], stats: { total_waiting: 0, total_notified: 1 } }) }
    mount(activeTool)
    await screen.findByText('No waitlist entries found.')
    const notifyNext = screen.getByRole('button', { name: 'Notify Next' })
    expect(notifyNext).toBeDisabled()
    expect(notifyNext).toHaveAccessibleDescription('No one is waiting to be notified.')
    await userEvent.click(notifyNext)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
})

it('shows address readiness and a delivery failure before organizer waitlist retry', async () => {
  activeTool = tools[2]
  apiClient.get.mockImplementation((path, config) => {
    if (path.endsWith('/waitlist')) return Promise.resolve({ data: {
      waitlist: [{ ...tools[2].row('actor-a'), delivery_failure: 'mailing address missing' }],
      stats: { total_waiting: 1 }, marketing_address_ready: false,
    } })
    return load(path, config)
  })
  mount(tools[2])
  expect(await screen.findByText(/add and certify the business mailing address/)).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Settings' })).toHaveAttribute('href', '/dashboard/settings')
  expect(screen.getByRole('button', { name: 'Notify Next' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Offer' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Offer' })).toHaveAttribute('aria-describedby', 'waitlist-address-required')
  expect(screen.getByText(/Couldn't send: mailing address missing/)).toBeInTheDocument()
})
