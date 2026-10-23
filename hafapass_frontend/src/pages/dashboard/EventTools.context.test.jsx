import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import EventStaffPage from './EventStaffPage'
import SalesToolsPage from './SalesToolsPage'
import SeatingManagementPage from './SeatingManagementPage'

const caps = vi.hoisted(() => ({ advanced_sales_tools: true, assigned_seating: true }))
vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() } }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => caps }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children, event }) => <div><h1>{event?.title}</h1>{children}</div> }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const permissions = { manage_staff: true, manage_inventory: true, manage_events: true, manage_marketing: true, edit_event_content: true, view_attendees: true }
const dto = id => ({ id, organization_id: 1, title: id === 11 ? 'Alpha private event' : 'Beta private event', slug: `event-${id}`, venue_id: 3,
  permissions, fee_policy: 'buyer_pays', buyer_fee_percent: 100, transfers_enabled: true, supported_locales: [], localized_content: {}, ticket_types: [{ id: 17, name: 'General', price_cents: 1000 }] })
const tools = [
  { name: 'Staff', path: 'team', Component: EventStaffPage, ready: () => screen.findByRole('button', { name: 'Assign' }), draft: () => screen.getByRole('combobox', { name: 'Event role' }), enter: user => user.selectOptions(screen.getByRole('combobox', { name: 'Event role' }), 'manager'), value: 'manager', save: () => screen.getByRole('button', { name: 'Assign' }), retry: 'Retry staff list' },
  { name: 'Sales', path: 'sales-tools', Component: SalesToolsPage, ready: () => screen.findByRole('button', { name: 'Save languages' }), draft: () => within(screen.getByRole('heading', { name: 'Extras, merchandise and donations' }).closest('section')).getByLabelText('Item name'), enter: user => user.type(within(screen.getByRole('heading', { name: 'Extras, merchandise and donations' }).closest('section')).getByLabelText('Item name'), 'Draft extra'), value: 'Draft extra', save: () => screen.getByRole('button', { name: 'Add item', exact: true }), retry: 'Retry sales tools' },
  { name: 'Seating', path: 'seating', Component: SeatingManagementPage, ready: () => screen.findByRole('button', { name: 'Create reusable layout' }), draft: () => screen.getByLabelText('Layout name'), enter: async user => { await user.clear(screen.getByLabelText('Layout name')); await user.type(screen.getByLabelText('Layout name'), 'Draft layout') }, value: 'Draft layout', save: () => screen.getByRole('button', { name: 'Create reusable layout' }), retry: 'Retry seating operations' },
]
let clearAuth, rows, getDefault
const bind = (userId = 'owner-a', sessionId = 'session-a') => {
  window.localStorage.setItem('hafapass_scanner_user_id', userId)
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId, sessionId, ready: true })
}
const mount = tool => render(<MemoryRouter initialEntries={[`/dashboard/events/11/${tool.path}`]}>
  <Link to={`/dashboard/events/11/${tool.path}`}>Open Alpha</Link><Link to={`/dashboard/events/22/${tool.path}`}>Open Beta</Link><Link to='/dashboard/events/11/other'>Leave tool</Link>
  <Routes><Route path='/dashboard/events/:id/*' element={<tool.Component />} /></Routes>
</MemoryRouter>)

beforeEach(() => {
  vi.clearAllMocks()
  for (const method of ['get', 'post', 'put', 'delete']) apiClient[method].mockReset()
  window.localStorage.clear(); window.sessionStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '1'); bind()
  caps.advanced_sales_tools = true; caps.assigned_seating = true
  rows = { 11: dto(11), 22: dto(22) }
  getDefault = (path, config) => {
    if (config?.organizationId === '2') return Promise.reject({ response: { status: 404, data: { error: 'Unavailable in this organization' } } })
    const eventMatch = path.match(/^\/organizer\/events\/(\d+)$/)
    if (eventMatch) return Promise.resolve({ data: rows[eventMatch[1]] })
    if (path.endsWith('/staff_assignments')) return Promise.resolve({ data: { assignments: [], candidates: [{ user_id: 7, name: 'Synthetic member', email: 'member@example.test', organization_role: 'scanner' }] } })
    if (path.endsWith('/seating')) return Promise.resolve({ data: { assigned_seating: false } })
    if (path === '/organizer/venue_layouts') return Promise.resolve({ data: { venue_layouts: [{ id: 41, name: 'Layout A', status: 'published', seat_count: 2 }, { id: 42, name: 'Layout B', status: 'published', seat_count: 2 }] } })
    if (/\/organizer\/venue_layouts\/\d+$/.test(path)) return Promise.resolve({ data: { id: Number(path.split('/').at(-1)), price_zones: [{ id: 2, name: 'Main zone' }] } })
    const resource = path.split('/').at(-1)
    return Promise.resolve({ data: resource === 'segments' ? { segments: {} } : { [resource]: [] } })
  }
  apiClient.get.mockImplementation(getDefault)
  apiClient.post.mockResolvedValue({ data: { id: 51, user_id: 7, role: 'manager', status: 'active', email: 'assigned@example.test' } })
  apiClient.put.mockResolvedValue({ data: {} }); apiClient.delete.mockResolvedValue({ data: {} })
})
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null; vi.unstubAllGlobals() })

it('leaves fee policy to the event edit page so it is not duplicated in sales tools', async () => {
  mount(tools[1]); await tools[1].ready()
  expect(screen.queryByRole('combobox', { name: 'Fee policy' })).not.toBeInTheDocument()
  expect(screen.queryByTestId('fee-terms-note')).not.toBeInTheDocument()
})

it('renders mapped and unknown actions in the active seating audit trail', async () => {
  apiClient.get.mockImplementation((path, config) => path.endsWith('/seating') ? Promise.resolve({ data: {
    assigned_seating: true, sections: [], audit_events: [
      { id: 1, action: 'partially_refunded', occurred_at: '2026-10-21T09:00:00Z' },
      { id: 2, action: 'accessible_seats_released', occurred_at: '2026-10-21T10:00:00Z' },
    ],
  } }) : getDefault(path, config))
  mount(tools[2])
  const audit = (await screen.findByRole('heading', { name: 'Audit trail' })).closest('section')
  expect(within(audit).getByText('Partially refunded')).toBeVisible()
  expect(within(audit).getByText('Accessible seats released')).toBeVisible()
  expect(within(audit).getAllByRole('listitem')).toHaveLength(2)
  expect(within(audit).queryByText(/partially_refunded|accessible_seats_released/)).not.toBeInTheDocument()
})

describe.each(tools)('$name organizer tool ownership and recovery', tool => {
  it.each(['success', 'error'])('discards an old event load %s after opening another event', async outcome => {
    const old = deferred()
    apiClient.get.mockImplementation((path, config) => path === '/organizer/events/11' ? old.promise : getDefault(path, config))
    mount(tool)
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    const config = apiClient.get.mock.calls[0][1]
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await tool.ready()
    const user = userEvent.setup(); await tool.enter(user)
    await act(async () => outcome === 'success' ? old.resolve({ data: rows[11] }) : old.reject(new Error('old failure')))
    expect(screen.queryByRole('heading', { name: 'Alpha private event' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Beta private event' })).toBeInTheDocument()
    expect(tool.draft()).toHaveValue(tool.value)
    expect(config.authContext.userId).toBe('owner-a'); expect(config.organizationId).toBe('1'); expect(config.signal.aborted).toBe(true)
  })

  it('withdraws a retained route and never revives its delayed data on return', async () => {
    const old = deferred(); let first = true
    apiClient.get.mockImplementation((path, config) => { if (path === '/organizer/events/11' && first) { first = false; return old.promise } return getDefault(path, config) })
    mount(tool)
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await userEvent.click(screen.getByRole('link', { name: 'Leave tool' }))
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    rows[11] = { ...rows[11], title: 'Fresh Alpha visit' }
    await userEvent.click(screen.getByRole('link', { name: 'Open Alpha' })); await tool.ready()
    await act(async () => old.resolve({ data: dto(11) }))
    expect(screen.getByRole('heading', { name: 'Fresh Alpha visit' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Alpha private event' })).not.toBeInTheDocument()
  })

  it('clears private content on organization change and discards its old load', async () => {
    const old = deferred()
    apiClient.get.mockImplementation((path, config) => config?.organizationId === '1' ? old.promise : getDefault(path, config))
    mount(tool); await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await act(async () => { window.localStorage.setItem('hafapass_organization_id', '2'); window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' })) })
    expect(await screen.findByRole('alert')).toHaveTextContent('Unavailable in this organization')
    await act(async () => old.resolve({ data: rows[11] }))
    expect(screen.queryByRole('heading', { name: 'Alpha private event' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: tool.retry })).toBeInTheDocument()
    expect(apiClient.get.mock.calls.at(-1)[1].organizationId).toBe('2')
  })

  it.each(['success', 'error'])('discards late mutation %s without clearing the new account draft', async outcome => {
    const old = deferred(); apiClient.post.mockReturnValueOnce(old.promise)
    mount(tool); await tool.ready()
    const user = userEvent.setup(); await tool.enter(user); await user.click(tool.save())
    const oldConfig = apiClient.post.mock.calls[0][2]
    rows[11] = { ...rows[11], title: 'New account event' }
    await act(async () => bind('owner-b', 'session-b'))
    await tool.ready(); await tool.enter(user)
    await act(async () => outcome === 'success' ? old.resolve({ data: { id: 77, email: 'old-private@example.test' } }) : old.reject(new Error('old failure')))
    expect(tool.draft()).toHaveValue(tool.value)
    expect(tool.save()).toBeEnabled()
    expect(screen.queryByText('old-private@example.test')).not.toBeInTheDocument()
    expect(screen.queryByText(/response was not confirmed/)).not.toBeInTheDocument()
    expect(oldConfig.authContext.userId).toBe('owner-a'); expect(oldConfig.signal.aborted).toBe(true)
  })

  it('offers retry for a failed initial load without presenting a false empty form', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline'))
    mount(tool)
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: tool.retry }))
    await tool.ready()
  })

  it('retains a rejected mutation draft and permits correction', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Please correct this configuration' } } })
    mount(tool); await tool.ready(); const user = userEvent.setup(); await tool.enter(user); await user.click(tool.save())
    expect(await screen.findByRole('alert')).toHaveTextContent('Please correct this configuration')
    expect(tool.draft()).toHaveValue(tool.value); expect(tool.save()).toBeEnabled()
  })

  it('keeps an unknown mutation locked across remount until saved-data review, without reposting', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('connection lost'))
    const view = mount(tool); await tool.ready(); const user = userEvent.setup(); await tool.enter(user); await user.click(tool.save())
    expect(await screen.findByRole('alert')).toHaveTextContent('not confirmed')
    expect(tool.save()).toBeDisabled(); expect(tool.draft()).toHaveValue(tool.value)
    view.unmount(); mount(tool); await tool.ready()
    expect(tool.save()).toBeDisabled()
    const verify = screen.getByRole('button', { name: /I verified/ })
    await waitFor(() => expect(verify).toBeEnabled())
    await user.click(verify)
    expect(tool.save()).toBeEnabled(); expect(apiClient.post).toHaveBeenCalledTimes(1)
  })
})

it('refreshing sales resources preserves an unsaved language setting and another draft', async () => {
  mount(tools[1]); await tools[1].ready()
  const user = userEvent.setup()
  await user.click(screen.getByLabelText('Japanese'))
  await user.type(screen.getByLabelText('Waiver title'), 'Unsubmitted waiver')
  await tools[1].enter(user); await user.click(tools[1].save())
  await waitFor(() => expect(tools[1].draft()).toHaveValue(''))
  await waitFor(() => expect(screen.getByText('Save configuration confirmed. Refreshing saved data.')).toBeInTheDocument())
  expect(screen.getByLabelText('Japanese')).toBeChecked()
  expect(screen.getByLabelText('Waiver title')).toHaveValue('Unsubmitted waiver')
})

it('loads only marketing resources and does not expose attendee export or inventory forms to a marketer', async () => {
  rows[11] = { ...rows[11], permissions: { manage_marketing: true } }
  mount(tools[1]); await screen.findByRole('heading', { name: 'Promoters and referral commission' })
  expect(screen.queryByRole('heading', { name: 'Extras, merchandise and donations' })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Save languages' })).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Export CSV' })).toBeDisabled()
  expect(apiClient.get.mock.calls.map(([path]) => path)).toEqual(['/organizer/events/11', '/organizer/events/11/promoters', '/organizer/events/11/communication_campaigns'])
})

it('does not enable seating activation while layout details are pending or use an older layout mapping', async () => {
  const old = deferred()
  apiClient.get.mockImplementation((path, config) => path === '/organizer/venue_layouts/41' ? old.promise : path === '/organizer/venue_layouts/42' ? Promise.resolve({ data: { id: 42, price_zones: [{ id: 2, name: 'Beta zone' }] } }) : getDefault(path, config))
  mount(tools[2]); await tools[2].ready(); const user = userEvent.setup()
  await user.selectOptions(screen.getByLabelText('Published venue layout'), '41')
  expect(screen.getByRole('button', { name: 'Activate assigned seating' })).toBeDisabled()
  await user.selectOptions(screen.getByLabelText('Published venue layout'), '42')
  await screen.findByLabelText('Beta zone ticket type')
  await act(async () => old.resolve({ data: { id: 41, price_zones: [{ id: 1, name: 'Old zone' }] } }))
  expect(screen.queryByLabelText('Old zone ticket type')).not.toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Activate assigned seating' }))
  expect(apiClient.post.mock.calls[0][1]).toEqual({ venue_layout_id: 42, zone_ticket_types: { 2: 17 } })
  expect(apiClient.post.mock.calls[0][2].authContext).toBe(getApiAuthContext())
})

it('shows the server reason when a layout with an unpaired wheelchair space is refused', async () => {
  const reason = 'This layout has 1 wheelchair space without a companion seat: Main floor · Row A · Seat 1. Give each wheelchair space a companion seat in the same companion group, then publish the layout again.'
  apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: reason } } })
  mount(tools[2]); await tools[2].ready(); const user = userEvent.setup()
  await user.selectOptions(screen.getByLabelText('Published venue layout'), '42')
  await screen.findByLabelText('Main zone ticket type')
  await user.selectOptions(screen.getByLabelText('Main zone ticket type'), '17')
  await user.click(screen.getByRole('button', { name: 'Activate assigned seating' }))
  expect(await screen.findByRole('alert')).toHaveTextContent(reason)
})

it('does not grant staff or seating controls without server permission or an enabled seating flag', async () => {
  rows[11] = { ...rows[11], permissions: { view_events: true } }
  const view = mount(tools[0])
  await screen.findByText('Your role doesn’t include managing this event’s team. Ask your organization owner if you need it.')
  expect(apiClient.get).toHaveBeenCalledTimes(1); expect(screen.queryByRole('button', { name: 'Assign' })).not.toBeInTheDocument()
  view.unmount(); rows[11] = dto(11); caps.assigned_seating = false
  mount(tools[2]); await screen.findByText('Assigned seating is not enabled for this platform.')
  expect(screen.queryByRole('button', { name: 'Activate assigned seating' })).not.toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
})

it('does not download a late attendee export after the account changes', async () => {
  const old = deferred()
  const createObjectURL = vi.fn(), revokeObjectURL = vi.fn()
  const NativeURL = URL
  vi.stubGlobal('URL', class extends NativeURL { static createObjectURL = createObjectURL; static revokeObjectURL = revokeObjectURL })
  apiClient.get.mockImplementation((path, config) => path.endsWith('/crm/export') ? old.promise : getDefault(path, config))
  mount(tools[1]); await tools[1].ready()
  await userEvent.click(screen.getByRole('button', { name: 'Export CSV' }))
  const config = apiClient.get.mock.calls.find(([path]) => path.endsWith('/crm/export'))[1]
  await act(async () => bind('owner-b', 'session-b'))
  await tools[1].ready()
  await act(async () => old.resolve({ data: new Blob(['Private Alpha attendee']) }))
  expect(createObjectURL).not.toHaveBeenCalled(); expect(revokeObjectURL).not.toHaveBeenCalled()
  expect(config.responseType).toBe('blob'); expect(config.authContext.userId).toBe('owner-a'); expect(config.signal.aborted).toBe(true)
})

it('shows an unconfirmed campaign submission without blindly sending it again', async () => {
  apiClient.get.mockImplementation((path, config) => path.endsWith('/communication_campaigns') ? Promise.resolve({ data: { communication_campaigns: [{ id: 99, name: 'Synthetic campaign', status: 'draft', recipient_count: 2 }] } }) : getDefault(path, config))
  apiClient.post.mockRejectedValueOnce(new Error('lost send response'))
  mount(tools[1]); await tools[1].ready()
  const send = screen.getByRole('button', { name: 'Send now' })
  await userEvent.click(send)
  expect(await screen.findByRole('alert')).toHaveTextContent('not confirmed')
  expect(send).toBeDisabled()
  await userEvent.click(screen.getByRole('button', { name: 'Refresh saved data' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'I verified the saved data' })).toBeEnabled())
  expect(send).toBeDisabled()
  expect(apiClient.post).toHaveBeenCalledTimes(1)
  expect(apiClient.post.mock.calls[0][0]).toBe('/organizer/events/11/communication_campaigns/99/send_now')
  expect(apiClient.post.mock.calls[0][1]).toBeUndefined()
})

it.each(tools)('keeps $name writes paused for a present invalid journal shape', async tool => {
  const name = tool.name === 'Staff' ? 'team' : tool.name === 'Sales' ? 'sales-tools' : 'seating'
  window.sessionStorage.setItem(`hafapass:${name}-outcome:owner-a:1:11`, 'false')
  mount(tool); await tool.ready()
  expect(tool.save()).toBeDisabled()
  expect(apiClient.post).not.toHaveBeenCalled()
  expect(window.sessionStorage.getItem(`hafapass:${name}-outcome:owner-a:1:11`)).toBe('false')
})
it('pauses staff changes while a previous saved-list refresh is unresolved', async () => {
  mount(tools[0]); await tools[0].ready()
  const delayed = deferred()
  apiClient.get.mockImplementation((path, config) => path.endsWith('/staff_assignments') ? delayed.promise : getDefault(path, config))
  await userEvent.click(screen.getByRole('button', { name: 'Refresh saved staff' }))
  expect(screen.getByRole('button', { name: 'Assign' })).toBeDisabled()
  await userEvent.click(screen.getByRole('button', { name: 'Assign' }))
  expect(apiClient.post).not.toHaveBeenCalled()
  await act(async () => delayed.resolve({ data: { assignments: [], candidates: [{ user_id: 7, name: 'Synthetic member', organization_role: 'scanner' }] } }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Assign' })).toBeEnabled())
  await userEvent.click(screen.getByRole('button', { name: 'Assign' }))
  expect(await screen.findByText('assigned@example.test')).toBeInTheDocument()
  expect(apiClient.post).toHaveBeenCalledTimes(1)
})

it('gives every sales tool input a visible label and keeps add actions secondary', async () => {
  mount(tools[1])
  await screen.findByRole('button', { name: 'Save languages' })
  for (const label of ['Item name', 'Type', 'Price ($)', 'Inventory', 'Question', 'Answer type', 'Choices (comma separated)', 'Waiver title', 'Version', 'Waiver text',
    'Promoter name', 'Promoter email', 'Referral code', 'Commission (%)', 'Internal campaign name', 'Email subject', 'Recipients', 'Send at (optional)', 'Message']) {
    expect(screen.getByLabelText(label)).toBeVisible()
  }
  expect(screen.getByLabelText('Item name')).toHaveAttribute('placeholder', 'e.g. Event T-shirt')
  for (const name of ['Add item', 'Add question', 'Add waiver', 'Add promoter']) {
    const button = screen.getByRole('button', { name })
    expect(button).toHaveClass('btn-secondary')
    expect(button).not.toHaveClass('btn-primary')
  }
})

it('offers every buyer language for organizer wording and shows automatic translation status', async () => {
  rows[11] = { ...rows[11], supported_locales: ['en', 'ch'], localized_content: { ch: { title: 'Fiestan Puesta' } },
    automatic_translation_available: true, translation_status: 'failed' }
  mount(tools[1]); await tools[1].ready()
  const user = userEvent.setup()
  const section = screen.getByRole('heading', { name: 'Public languages' }).closest('section')

  for (const label of ['Korean', 'Japanese', 'Chinese (Traditional)', 'Chinese (Simplified)', 'Filipino', 'CHamoru']) {
    expect(within(section).getByLabelText(label)).toBeInTheDocument()
  }
  expect(within(section).getByLabelText('CHamoru')).toBeChecked()
  expect(within(section).getByRole('status')).toHaveTextContent('Automatic translation did not finish')

  await user.click(within(section).getByLabelText('Chinese (Traditional)'))
  const panel = within(section).getByText('Chinese (Traditional) public content').closest('div')
  await user.type(within(panel).getByLabelText('Translated title'), '日落節')
  await user.click(within(section).getByRole('button', { name: 'Save languages' }))
  await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/11', {
    supported_locales: ['en', 'ch', 'zh-Hant'],
    localized_content: { ch: { title: 'Fiestan Puesta' }, 'zh-Hant': { title: '日落節' } },
  }, expect.anything()))

  await waitFor(() => expect(within(section).getByRole('button', { name: 'Translate again' })).toBeEnabled())
  await user.click(within(section).getByRole('button', { name: 'Translate again' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/11/retranslate', undefined, expect.anything()))
})

it('hides CHamoru for events that never used it and explains when translation is not set up', async () => {
  mount(tools[1]); await tools[1].ready()
  const section = screen.getByRole('heading', { name: 'Public languages' }).closest('section')
  expect(within(section).queryByLabelText('CHamoru')).not.toBeInTheDocument()
  expect(within(section).getByRole('status')).toHaveTextContent('Automatic translation is not set up yet')
  expect(within(section).queryByRole('button', { name: 'Translate again' })).not.toBeInTheDocument()
})

it('polls while translating, explains a paused service and flags wording whose English changed', async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  try {
    rows[11] = { ...rows[11], supported_locales: ['en', 'ko'], localized_content: { ko: { title: '선셋' } },
      localized_content_stale: { ko: ['title'] }, automatic_translation_available: true, translation_status: 'pending' }
    mount(tools[1]); await tools[1].ready()
    const section = screen.getByRole('heading', { name: 'Public languages' }).closest('section')
    expect(within(section).getByRole('group', { name: 'Use your own wording for:' })).toBeInTheDocument()
    expect(within(section).getByText('English changed since you wrote this. Review it before saving.')).toBeInTheDocument()
    expect(within(section).getByRole('status')).toHaveTextContent('Translating your latest changes')
    const eventLoads = () => apiClient.get.mock.calls.filter(([path]) => path === '/organizer/events/11').length
    const before = eventLoads()

    rows[11] = { ...rows[11], translation_status: 'unavailable' }
    await act(async () => { await vi.advanceTimersByTimeAsync(5000) })
    await waitFor(() => expect(eventLoads()).toBe(before + 1))
    expect(within(section).getByRole('status')).toHaveTextContent('Automatic translation is paused for now')

    await act(async () => { await vi.advanceTimersByTimeAsync(10000) })
    expect(eventLoads()).toBe(before + 1)
  } finally {
    vi.useRealTimers()
  }
})


it.each(['draft', 'scheduled'])('recovers a failed campaign as %s after reviewing saved content', async status => {
  const campaign = { id: 99, name: 'Door reminder', subject: 'Doors open soon', body: 'Bring your ticket.',
    segment: { type: 'ticket_type', ticket_type_id: 17 }, status: 'failed', recipient_count: 0,
    last_error: 'Needs attention: review and reschedule this campaign.' }
  apiClient.get.mockImplementation((path, config) => path.endsWith('/communication_campaigns')
    ? Promise.resolve({ data: { communication_campaigns: [campaign] } }) : getDefault(path, config))
  apiClient.put.mockImplementation(async (path, payload) => {
    Object.assign(campaign, payload, { status, last_error: null })
    return { data: campaign }
  })
  mount(tools[1])
  await userEvent.click(await screen.findByRole('button', { name: 'Review and reschedule' }))
  expect(screen.getByLabelText('Internal campaign name')).toHaveValue('Door reminder')
  expect(screen.getByLabelText('Internal campaign name')).toHaveFocus()
  expect(screen.getByLabelText('Email subject')).toHaveValue('Doors open soon')
  expect(screen.getByLabelText('Message')).toHaveValue('Bring your ticket.')
  expect(screen.getByLabelText('Ticket type')).toHaveValue('17')
  expect(screen.getByText(/Saving does not send email/)).toBeVisible()
  await userEvent.clear(screen.getByLabelText('Email subject'))
  await userEvent.type(screen.getByLabelText('Email subject'), 'Reviewed subject')
  if (status === 'scheduled') await userEvent.type(screen.getByLabelText('Send at (optional)'), '2030-10-24T18:00')
  await userEvent.click(screen.getByRole('button', { name: 'Save campaign changes' }))
  await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/11/communication_campaigns/99',
    expect.objectContaining({ subject: 'Reviewed subject', segment: { type: 'ticket_type', ticket_type_id: 17 }, scheduled_at: status === 'scheduled' ? '2030-10-24T18:00' : null }), expect.anything()))
  expect(apiClient.post).not.toHaveBeenCalled()
  await userEvent.click(await screen.findByRole('button', { name: 'Send now' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/11/communication_campaigns/99/send_now', undefined, expect.anything())
})

it('retains failed campaign edits after validation fails', async () => {
  apiClient.get.mockImplementation((path, config) => path.endsWith('/communication_campaigns')
    ? Promise.resolve({ data: { communication_campaigns: [{ id: 99, name: 'Reminder', body: 'Saved message', status: 'failed' }] } }) : getDefault(path, config))
  apiClient.put.mockRejectedValue({ response: { status: 422, data: { errors: ['Subject is required'] } } })
  mount(tools[1])
  await userEvent.click(await screen.findByRole('button', { name: 'Review and reschedule' }))
  await userEvent.click(screen.getByRole('button', { name: 'Save campaign changes' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Subject is required')
  expect(screen.getByLabelText('Message')).toHaveValue('Saved message')
  expect(screen.getByRole('button', { name: 'Save campaign changes' })).toBeEnabled()
})

it('hides campaign recovery and send actions from members without marketing permission', async () => {
  rows[11] = { ...rows[11], permissions: { view_attendees: true } }
  mount(tools[1]); await screen.findByRole('heading', { name: 'CRM and attendee communication' })
  expect(screen.queryByRole('button', { name: 'Review and reschedule' })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Send now' })).not.toBeInTheDocument()
  expect(screen.queryByLabelText('Message')).not.toBeInTheDocument()
})
