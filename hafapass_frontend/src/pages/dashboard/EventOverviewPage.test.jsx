import { render, screen, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import EventOverviewPage from './EventOverviewPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const manager = { view_events: true, manage_events: true, edit_event_content: true, manage_inventory: true, view_attendees: true,
  manage_attendees: true, manage_marketing: true, manage_staff: true, scan: true, box_office: true, view_finance: true }
const base = { id: 37, organization_id: 1, organization_name: 'Island events', title: 'Synthetic reef night', slug: 'synthetic-reef-night',
  starts_at: '2026-11-20T09:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Tumon pavilion', status: 'published',
  ticket_types: [{ id: 1, quantity_available: 100, quantity_sold: 40 }], publish_checklist: [], permissions: manager }

function mount(event, extra = {}) {
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/organizations') return Promise.resolve({ data: [{ id: 1, name: 'Island events' }] })
    if (path === '/organizer/events/37') return Promise.resolve({ data: event })
    if (path in extra) return Promise.resolve({ data: extra[path] })
    return Promise.reject(new Error(`Unexpected ${path}`))
  })
  return render(<MemoryRouter initialEntries={['/dashboard/events/37']}><Routes>
    <Route path="/dashboard/events/:id" element={<EventOverviewPage />} />
  </Routes></MemoryRouter>)
}
const requested = path => apiClient.get.mock.calls.some(([url]) => url === path)
const tools = () => within(screen.getByRole('region', { name: 'Event tools' })).getAllByRole('link').map(link => [link.textContent, link.getAttribute('href')])

beforeEach(() => { vi.clearAllMocks(); window.localStorage.clear(); window.localStorage.setItem('hafapass_organization_id', '1') })

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
    expect(tools().map(([label]) => label)).toEqual(['Edit event', 'Ticket types', 'Attendee list', 'Scan tickets', 'Box office', 'Promo codes', 'Event team', 'Sales & finances'])
    expect(screen.getByRole('link', { name: 'Overview' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByText('Island events')).toBeInTheDocument()
    expect(requested('/organizer/events/37/admissions')).toBe(false)
  })

  it('walks a draft through its open publish checks with a link to finish setup', async () => {
    mount({ ...base, status: 'draft', permissions: { view_events: true, manage_events: true, edit_event_content: true },
      publish_checklist: [{ code: 'title', label: 'Event title added', complete: true }, { code: 'tickets', label: 'At least one ticket type added', complete: false }] })
    const next = await screen.findByRole('region', { name: 'Next steps' })
    expect(next).toHaveTextContent('1 of 2 publish checks done.')
    expect(next).toHaveTextContent('At least one ticket type added')
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
})
