import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import EventOverviewPage from './EventOverviewPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn() } }))
const launch = vi.hoisted(() => ({}))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => launch }))

const manager = { view_events: true, manage_events: true, edit_event_content: true, manage_inventory: true, view_attendees: true,
  manage_attendees: true, manage_marketing: true, manage_staff: true, scan: true, box_office: true, view_finance: true }
const base = { id: 37, organization_id: 1, organization_name: 'Island events', title: 'Synthetic reef night', slug: 'synthetic-reef-night',
  starts_at: '2026-11-20T09:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Tumon pavilion', status: 'published',
  ticket_types: [{ id: 1, quantity_available: 100, quantity_sold: 40 }], publish_checklist: [], permissions: manager }

function mount(event, extra = {}, organization = { id: 1, name: 'Island events' }) {
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/organizations') return Promise.resolve({ data: [organization] })
    if (path === '/organizer/events/37') return Promise.resolve({ data: event })
    if (path in extra) return typeof extra[path] === 'function' ? extra[path]() : Promise.resolve({ data: extra[path] })
    return Promise.reject(new Error(`Unexpected ${path}`))
  })
  return render(<MemoryRouter initialEntries={['/dashboard/events/37']}><Routes>
    <Route path="/dashboard/events/:id" element={<EventOverviewPage />} />
  </Routes></MemoryRouter>)
}
const requested = path => apiClient.get.mock.calls.some(([url]) => url === path)
const tools = () => within(screen.getByRole('region', { name: 'Event tools' })).getAllByRole('link').map(link => [link.textContent, link.getAttribute('href')])

const sidebarTools = () => within(screen.getByRole('navigation', { name: 'Event workspace' })).getAllByRole('link')
  .map(link => [link.textContent, link.getAttribute('href')]).filter(([label]) => label !== 'Overview')
const clipboard = Object.getOwnPropertyDescriptor(window.navigator, 'clipboard')
const setClipboard = value => Object.defineProperty(window.navigator, 'clipboard', { configurable: true, value })

beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.localStorage.setItem('hafapass_organization_id', '1')
  for (const key of Object.keys(launch)) delete launch[key]
  if (clipboard) Object.defineProperty(window.navigator, 'clipboard', clipboard)
  else delete window.navigator.clipboard
})

describe('event overview', () => {
  it('shows live sales, check-ins, sharing and every manager tool for a published event', async () => {
    mount(base, { '/organizer/events/37/stats': { total_tickets_sold: 42, total_revenue_cents: 105000, tickets_checked_in: 10 } })
    const sales = await screen.findByRole('region', { name: 'Sales so far' })
    expect(await within(sales).findByText('$1,050.00')).toBeInTheDocument()
    expect(sales).toHaveTextContent('Tickets sold42 / 100')
    expect(sales).toHaveTextContent('Checked in10 / 42')
    expect(screen.getByRole('link', { name: 'View public page' })).toHaveAttribute('href', '/events/synthetic-reef-night')
    expect(screen.getByRole('button', { name: 'Copy event link' })).toBeInTheDocument()
    expect(within(screen.getByRole('region', { name: 'Next steps' })).getByRole('link', { name: 'Scan tickets' })).toHaveAttribute('href', '/dashboard/scanner?event=37')
    expect(tools().map(([label]) => label)).toEqual(['Edit event', 'Ticket types', 'Attendee list', 'Guest list', 'Waitlist', 'Scan tickets', 'Box office', 'Promo codes', 'Event team', 'Sales & finances'])
    expect(screen.getByRole('link', { name: 'Overview' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByText('Island events')).toBeInTheDocument()
    expect(requested('/organizer/events/37/admissions')).toBe(false)
  })

  it('walks a draft through its open publish checks with a link to finish setup', async () => {
    mount({ ...base, status: 'draft', permissions: { view_events: true, manage_events: true, edit_event_content: true },
      publish_checklist: [{ code: 'title', label: 'Event title added', complete: true }, { code: 'tickets', label: 'At least one ticket type added', complete: false },
        { code: 'retired_launch_gate', label: 'Internal review', complete: false }] })
    const next = await screen.findByRole('region', { name: 'Next steps' })
    expect(next).toHaveTextContent('1 of 2 publish checks done.')
    expect(next).toHaveTextContent('Add at least one ticket type')
    expect(next).not.toHaveTextContent('Internal review')
    expect(within(next).getByRole('link', { name: 'Finish setup' })).toHaveAttribute('href', '/dashboard/events/37/edit')
    expect(screen.queryByRole('link', { name: 'View public page' })).not.toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Sales so far' })).not.toHaveTextContent('Revenue')
    expect(requested('/organizer/events/37/stats')).toBe(false)
  })

  it('gives door staff check-in progress and only their tools, without finance requests', async () => {
    mount({ ...base, permissions: { view_events: true, scan: true } }, { '/organizer/events/37/admissions': { counts: { admitted: 5, remaining: 15 } } })
    const sales = await screen.findByRole('region', { name: 'Sales so far' })
    expect(await within(sales).findByText('Checked in')).toBeInTheDocument()
    expect(sales).toHaveTextContent('Checked in5 / 20')
    expect(sales).not.toHaveTextContent('Revenue')
    expect(tools()).toEqual([['Scan tickets', '/dashboard/scanner?event=37']])
    expect(requested('/organizer/events/37/stats')).toBe(false)
  })

  it('tells staff who cannot edit a draft who can publish it', async () => {
    mount({ ...base, status: 'draft', permissions: { view_events: true, scan: true }, publish_checklist: [{ code: 'tickets', label: 'Tickets', complete: false }] })
    expect(await screen.findByText('Ask an event manager to finish setup and publish.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Finish setup' })).not.toBeInTheDocument()
  })

  it('explains a missing event and offers a retry', async () => {
    apiClient.get.mockImplementation(() => Promise.reject({ response: { status: 404 } }))
    render(<MemoryRouter initialEntries={['/dashboard/events/37']}><Routes><Route path="/dashboard/events/:id" element={<EventOverviewPage />} /></Routes></MemoryRouter>)
    expect(await screen.findByRole('alert')).toHaveTextContent('Event not found.')
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'All events' })).toHaveAttribute('href', '/dashboard')
  })

  it('offers exactly the workspace tools, including refunds and sales tools when granted', async () => {
    launch.advanced_sales_tools = true; launch.assigned_seating = true
    mount({ ...base, permissions: { ...manager, refund: true } }, { '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 } })
    await screen.findByRole('region', { name: 'Event tools' })
    const labels = tools().map(([label]) => label)
    expect(labels).toEqual(expect.arrayContaining(['Refunds', 'Sales tools & messages', 'Assigned seating']))
    expect(tools()).toEqual(sidebarTools())
  })

  it('formats revenue in the organization currency', async () => {
    mount(base, { '/organizer/events/37/stats': { total_tickets_sold: 1, total_revenue_cents: 105000, tickets_checked_in: 0 } }, { id: 1, name: 'Island events', currency: 'eur' })
    expect(await screen.findByText('€1,050.00')).toBeInTheDocument()
  })

  it('shows placeholders while sales figures load and a retry when they fail', async () => {
    let attempt = 0, resolveSecond
    mount(base, { '/organizer/events/37/stats': () => ++attempt === 1 ? Promise.reject(new Error('Synthetic outage'))
      : new Promise(resolve => { resolveSecond = resolve }) })
    const sales = await screen.findByRole('region', { name: 'Sales so far' })
    expect(await within(sales).findByRole('alert')).toHaveTextContent('Sales figures unavailable.')
    await userEvent.setup().click(within(sales).getByRole('button', { name: 'Retry' }))
    expect(within(sales).getByText('Loading sales figures…')).toBeInTheDocument()
    expect(within(sales).queryByRole('alert')).not.toBeInTheDocument()
    resolveSecond({ data: { total_tickets_sold: 2, total_revenue_cents: 5000, tickets_checked_in: 1 } })
    expect(await within(sales).findByText('$50.00')).toBeInTheDocument()
    expect(within(sales).queryByText('Loading sales figures…')).not.toBeInTheDocument()
  })

  it('confirms a copied event link', async () => {
    // user-event installs its own clipboard on setup, so replace it afterwards.
    const user = userEvent.setup()
    const writeText = vi.fn(() => Promise.resolve())
    setClipboard({ writeText })
    mount(base, { '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 } })
    await user.click(await screen.findByRole('button', { name: 'Copy event link' }))
    expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/\/events\/synthetic-reef-night$/))
    expect(await screen.findByRole('button', { name: 'Link copied' })).toBeInTheDocument()
  })

  it.each([
    ['writeText rejects', () => setClipboard({ writeText: vi.fn(() => Promise.reject(new Error('Denied'))) })],
    ['the clipboard is unavailable', () => setClipboard(undefined)],
  ])('falls back to a selectable link when %s', async (_case, prepare) => {
    const user = userEvent.setup()
    prepare()
    mount(base, { '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 } })
    await user.click(await screen.findByRole('button', { name: 'Copy event link' }))
    expect(await screen.findByText("Couldn't copy. Select the link below.")).toBeInTheDocument()
    const input = screen.getByRole('textbox', { name: 'Event link' })
    expect(input).toHaveAttribute('readonly')
    await waitFor(() => expect(input.value).toMatch(/\/events\/synthetic-reef-night$/))
  })
  it('never calls a published event live while HåfaPass has not verified the organizer', async () => {
    const user = userEvent.setup()
    apiClient.post.mockResolvedValue({ data: { verification_status: 'pending', verification_requested_at: '2026-10-21T00:30:00Z', organization: { role: 'owner' } } })
    mount({ ...base, sales_status: { on_sale: false, reason: 'organizer_not_verified', message: 'Visible but not on sale yet: waiting for HåfaPass to verify your organization.' } }, {
      '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 },
      '/organizer_profile': { verification_status: 'unverified', organization: { role: 'owner' } },
    })
    const next = await screen.findByRole('region', { name: 'Next steps' })
    expect(next).toHaveTextContent('Visible but not on sale yet.')
    expect(next).toHaveTextContent('Waiting for HåfaPass to verify your organization.')
    expect(next).not.toHaveTextContent('Your event is live')
    expect(screen.getByRole('region', { name: 'Overview' })).toHaveTextContent('tickets are not on sale yet')
    expect(within(next).getByRole('link', { name: 'View public page' })).toBeInTheDocument()
    expect(within(next).getByRole('link', { name: 'Scan tickets' })).toBeInTheDocument()
    await user.click(await within(next).findByRole('button', { name: 'Request verification' }))
    expect(apiClient.post).toHaveBeenCalledWith('/organizer_profile/submit_verification', {}, expect.objectContaining({ organizationId: '1' }))
    expect(await within(next).findByText(/Verification requested .* HåfaPass will review it soon\./)).toBeInTheDocument()
  })

  it('does not load the organizer profile when the event is on sale', async () => {
    mount({ ...base, sales_status: { on_sale: true, reason: null, message: null } }, { '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 } })
    expect(await screen.findByText('Your event is live. Share it and get ready for the door.')).toBeInTheDocument()
    expect(requested('/organizer_profile')).toBe(false)
  })

  it('says HåfaPass paused sales for the event and shows the reason', async () => {
    mount({ ...base, sales_status: { on_sale: false, reason: 'event_paused', message: 'Sales are paused.' }, policy_hold: { scope: 'sales', reason: 'Venue permit under review.' } },
      { '/organizer/events/37/stats': { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 } })
    const next = await screen.findByRole('region', { name: 'Next steps' })
    expect(next).toHaveTextContent('Sales paused by HåfaPass.')
    expect(next).toHaveTextContent('Venue permit under review.')
    expect(next).not.toHaveTextContent('Your event is live')
    expect(within(next).queryByRole('button', { name: /Request approval/ })).not.toBeInTheDocument()
  })
})
