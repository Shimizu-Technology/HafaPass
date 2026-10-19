import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes, useLocation, useParams } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import EventWorkspace from './EventWorkspace'

const launch = vi.hoisted(() => ({ assigned_seating: true, advanced_sales_tools: true }))
vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => launch }))
const permissions = { edit_event_content: true, manage_inventory: true, view_attendees: true, manage_attendees: true,
  scan: true, box_office: true, manage_marketing: true, manage_staff: true, view_finance: true, refund: true }
const dto = (id = 37, organizationId = 1) => ({ id, organization_id: organizationId, title: `Event ${id}: A long local event title that stays readable`,
  starts_at: '2026-11-20T09:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Synthetic Guam venue', status: 'published', permissions })
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const Location = () => <p data-testid="workspace-location">{useLocation().pathname}{useLocation().hash}</p>
function LoadedPage() { const { id } = useParams(); return <EventWorkspace eventId={id}><input aria-label="Working draft" defaultValue="Retained work" /></EventWorkspace> }
function mount({ event = dto(), path = '/dashboard/events/37/edit', dirty = false } = {}) {
  return render(<MemoryRouter initialEntries={[path]}><Location /><Routes>
    <Route path="/dashboard/events/:id/:tool" element={<EventWorkspace eventId={event.id} event={event} hasUnsavedChanges={dirty}><input aria-label="Working draft" defaultValue="Retained work" /></EventWorkspace>} />
    <Route path="/dashboard" element={<p>All events destination</p>} />
  </Routes></MemoryRouter>)
}
let clearAuth
const dialogMethods = Object.fromEntries(['showModal', 'close'].map(method => [method, Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, method)]))
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '1')
  launch.assigned_seating = true; launch.advanced_sales_tools = true
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organizations' ? [{ id: 1, name: 'Synthetic organizer' }] : dto() }))
  Object.defineProperty(HTMLDialogElement.prototype, 'showModal', { configurable: true, value: function () { this.open = true; this.querySelector('button')?.focus() } })
  Object.defineProperty(HTMLDialogElement.prototype, 'close', { configurable: true, value: function () { this.open = false } })
})
afterEach(() => {
  cleanup(); clearAuth?.(); clearAuth = null; vi.restoreAllMocks()
  for (const [method, descriptor] of Object.entries(dialogMethods)) {
    if (descriptor) Object.defineProperty(HTMLDialogElement.prototype, method, descriptor)
    else delete HTMLDialogElement.prototype[method]
  }
})

describe('connected event workspace', () => {
  it('shows full event identity, organization, effective access and seven actual route-backed groups', async () => {
    mount()
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(dto().title)
    expect(await screen.findByText('Synthetic organizer')).toBeInTheDocument()
    expect(screen.getByText('Synthetic Guam venue')).toBeInTheDocument()
    expect(screen.getByText(/Pacific\/Guam/)).toHaveTextContent('7:00 PM')
    expect(screen.getByText('Published', { exact: true })).toBeInTheDocument()
    expect(screen.getByText(/^Your access:/)).toHaveTextContent('Event details, Tickets & seating, Attendees, Event day, Sales & messages, Team, Finances')
    expect(screen.queryByRole('link', { name: 'Overview' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Edit event' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Refunds' })).toHaveAttribute('href', '/dashboard/events/37/refunds')
  })

  it('leads with the event overview for members who can view the event', () => {
    render(<MemoryRouter initialEntries={['/dashboard/events/37']}><Routes>
      <Route path="/dashboard/events/:id" element={<EventWorkspace eventId={37} event={{ ...dto(), permissions: { ...permissions, view_events: true } }}><p>Overview body</p></EventWorkspace>} />
    </Routes></MemoryRouter>)
    const links = within(screen.getByRole('navigation', { name: 'Event workspace' })).getAllByRole('link')
    expect(links[0]).toHaveTextContent('Overview')
    expect(links[0]).toHaveAttribute('href', '/dashboard/events/37')
    expect(links[0]).toHaveAttribute('aria-current', 'page')
    expect(screen.getByText(/^Your access:/)).not.toHaveTextContent('Overview')
    expect(screen.getByText('Overview body')).toBeInTheDocument()
  })

  it('shares the workspace navbar container so the left edge stays put', () => {
    mount()
    const shell = screen.getByRole('heading', { level: 1 }).closest('header').parentElement
    expect(shell).toHaveClass('mx-auto', 'max-w-6xl', 'px-4', 'sm:px-6', 'lg:px-8')
  })

  it.each([
    ['marketer', { edit_event_content: true, manage_marketing: true }, ['Edit event', 'Promo codes', 'Sales tools & messages']],
    ['finance', { view_finance: true, refund: true }, ['Sales & finances', 'Refunds']],
    ['box office', { view_attendees: true, manage_attendees: true, scan: true, box_office: true }, ['Attendee list', 'Guest list', 'Waitlist', 'Scan tickets', 'Box office']],
    ['scanner', { scan: true }, ['Scan tickets']],
    ['reader', { view_finance: true }, ['Sales & finances']],
  ])('only offers the tools granted to %s', (_role, scope, expected) => {
    mount({ event: { ...dto(), permissions: scope } })
    const tools = within(screen.getByRole('navigation', { name: 'Event workspace' })).getAllByRole('link')
    expect(tools.map(link => link.textContent)).toEqual(expected)
  })

  it('hides disabled capabilities while keeping baseline promo codes and all other permitted tools', () => {
    launch.assigned_seating = false; launch.advanced_sales_tools = false
    mount()
    expect(screen.queryByRole('link', { name: 'Assigned seating' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Sales tools & messages' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Promo codes' })).toBeInTheDocument()
  })

  it('highlights the current subpage without also selecting the event editor', () => {
    mount({ path: '/dashboard/events/37/guest-list' })
    expect(screen.getByRole('link', { name: 'Guest list' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Edit event' })).not.toHaveAttribute('aria-current')
    expect(screen.getByRole('link', { name: 'Ticket types' })).not.toHaveAttribute('aria-current')
  })

  it('keeps draft DOM and values when moving to tickets within the same editor', async () => {
    mount({ dirty: true })
    const input = screen.getByLabelText('Working draft')
    await userEvent.type(input, ' unsaved')
    await userEvent.click(screen.getByRole('link', { name: 'Ticket types' }))
    expect(screen.getByLabelText('Working draft')).toBe(input)
    expect(input).toHaveValue('Retained work unsaved')
    expect(screen.getByRole('link', { name: 'Ticket types' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('asks before abandoning dirty event fields, preserves them on stay, and allows explicit departure', async () => {
    mount({ dirty: true })
    await userEvent.type(screen.getByLabelText('Working draft'), ' unsaved')
    await userEvent.click(screen.getByRole('link', { name: 'Guest list' }))
    expect(screen.getByRole('dialog', { name: 'Leave unsaved event changes?' })).toBeInTheDocument()
    expect(screen.getByTestId('workspace-location')).toHaveTextContent('/dashboard/events/37/edit')
    await userEvent.click(screen.getByRole('button', { name: 'Stay and save' }))
    expect(screen.getByLabelText('Working draft')).toHaveValue('Retained work unsaved')
    await userEvent.click(screen.getByRole('link', { name: 'All events' }))
    await userEvent.click(screen.getByRole('button', { name: 'Leave without saving' }))
    expect(screen.getByText('All events destination')).toBeInTheDocument()
  })

  it('retains every tool when collapsed and persists the preference', async () => {
    mount()
    const tools = screen.getAllByRole('link').length
    await userEvent.click(screen.getByRole('button', { name: 'Collapse event navigation' }))
    expect(screen.getAllByRole('link')).toHaveLength(tools)
    expect(screen.getByRole('link', { name: 'Refunds' })).toHaveAttribute('title', 'Refunds')
    expect(window.localStorage.getItem('hafapass:event-workspace:collapsed')).toBe('true')
    cleanup(); mount()
    expect(screen.getByRole('button', { name: 'Expand event navigation' })).toBeInTheDocument()
  })

  it('opens a modal phone menu, closes on cancel with focus return, and closes on navigation', async () => {
    mount()
    const trigger = screen.getByRole('button', { name: 'Event navigation', exact: true })
    await userEvent.click(trigger)
    const dialog = screen.getByRole('dialog', { name: 'Event navigation' })
    expect(dialog).toHaveAttribute('open')
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    fireEvent(dialog, new Event('cancel', { cancelable: true }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
    await userEvent.click(trigger)
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('link', { name: 'Guest list' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByTestId('workspace-location')).toHaveTextContent('/dashboard/events/37/guest-list')
  })

  it('recovers a failed context load without unmounting the working input', async () => {
    let fail = true
    apiClient.get.mockImplementation(path => path === '/organizer/organizations' ? Promise.resolve({ data: [] })
      : fail ? Promise.reject(new Error('Synthetic outage')) : Promise.resolve({ data: dto() }))
    render(<MemoryRouter initialEntries={['/dashboard/events/37/refunds']}><Routes><Route path="/dashboard/events/:id/:tool" element={<LoadedPage />} /></Routes></MemoryRouter>)
    const input = screen.getByLabelText('Working draft')
    await userEvent.type(input, ' local')
    await screen.findByRole('alert')
    fail = false
    await userEvent.click(screen.getByRole('button', { name: 'Retry event navigation' }))
    await screen.findByRole('heading', { level: 1 })
    expect(screen.getByLabelText('Working draft')).toBe(input)
    expect(input).toHaveValue('Retained work local')
  })

  it.each(['success', 'error'])('cannot restore the old event after a delayed context %s and route change', async outcome => {
    const old = deferred()
    apiClient.get.mockImplementation(path => path === '/organizer/organizations' ? Promise.resolve({ data: [] })
      : path.endsWith('/11') ? old.promise : Promise.resolve({ data: dto(22) }))
    render(<MemoryRouter initialEntries={['/dashboard/events/11/guest-list']}><Link to="/dashboard/events/22/guest-list">Open Beta</Link>
      <Routes><Route path="/dashboard/events/:id/:tool" element={<LoadedPage />} /></Routes></MemoryRouter>)
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await screen.findByRole('heading', { name: dto(22).title })
    await act(async () => outcome === 'success' ? old.resolve({ data: dto(11) }) : old.reject(new Error('Old failure')))
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(dto(22).title)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Guest list' })).toHaveAttribute('href', '/dashboard/events/22/guest-list')
  })
  it.each(['organization', 'session'])('rejects old context responses across a %s replacement', async replacement => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'synthetic-actor')
    clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'synthetic-actor', sessionId: 'session-one', ready: true })
    const old = deferred()
    let oldEventRequested = false
    apiClient.get.mockImplementation((path, config) => {
      const organizationId = Number(config.organizationId)
      if (path === '/organizer/organizations') return Promise.resolve({ data: [{ id: organizationId, name: `Organizer ${organizationId}` }] })
      if (!oldEventRequested) { oldEventRequested = true; return old.promise }
      return Promise.resolve({ data: { ...dto(37, organizationId), title: 'Current actor event' } })
    })
    render(<MemoryRouter initialEntries={['/dashboard/events/37/refunds']}><Routes><Route path="/dashboard/events/:id/:tool" element={<LoadedPage />} /></Routes></MemoryRouter>)
    await act(async () => {
      if (replacement === 'organization') {
        window.localStorage.setItem('hafapass_organization_id', '2')
        window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      } else clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'synthetic-actor', sessionId: 'session-two', ready: true })
    })
    await screen.findByRole('heading', { name: 'Current actor event' })
    await act(async () => old.resolve({ data: { ...dto(), title: 'Previous actor event' } }))
    expect(screen.queryByRole('heading', { name: 'Previous actor event' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Current actor event' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Refunds' })).toHaveAttribute('href', '/dashboard/events/37/refunds')
  })

})

it('moves focus to the authorized ticket section without discarding the current dirty input', async () => {
  render(<MemoryRouter initialEntries={['/dashboard/events/37/edit']}><Location /><EventWorkspace eventId={37} event={dto()} hasUnsavedChanges><input aria-label="Working draft" defaultValue="Unsaved local text" /><section id="ticket-types" tabIndex={-1}><h2>Ticket editor section</h2></section></EventWorkspace></MemoryRouter>)
  const target = document.getElementById('ticket-types')
  target.scrollIntoView = vi.fn()
  await userEvent.click(screen.getByRole('link', { name: 'Ticket types', exact: true }))
  expect(target).toHaveFocus()
  expect(target.scrollIntoView).toHaveBeenCalledTimes(1)
  screen.getByLabelText('Working draft').focus()
  await userEvent.click(screen.getByRole('link', { name: 'Ticket types', exact: true }))
  expect(target).toHaveFocus()
  expect(target.scrollIntoView).toHaveBeenCalledTimes(2)
  expect(screen.getByLabelText('Working draft')).toHaveValue('Unsaved local text')
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  expect(screen.getByTestId('workspace-location')).toHaveTextContent('/dashboard/events/37/edit#ticket-types')
})
