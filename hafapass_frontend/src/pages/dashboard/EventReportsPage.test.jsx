import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { saveBlob } from '../../utils/download'
import EventReportsPage from './EventReportsPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

const base = '/organizer/events/37'
const path = '/dashboard/events/37/reports'
const event = { id: 37, organization_id: 1, slug: 'community-night', title: 'Community Night',
  permissions: { view_finance: true, view_attendees: true }, ticket_types: [{ id: 14, name: 'Alumni' }] }
const kpis = { gross_sales_cents: 5000, net_sales_cents: 4000, total_refunded_cents: 1000, unique_orders: 1 }
const responses = {
  sales_by_tier: { summary: kpis, sales_by_tier: [{
    ticket_type_id: 14, ticket_type_name: 'Alumni', pricing_tier_id: 6, tier_name: 'Early Bird', unit_price_cents: 2500,
    tickets_sold: 2, tickets_refunded_or_cancelled: 0, gross_cents: 5000, discount_cents: 0, net_cents: 4000, remaining_capacity: 12,
  }] },
  attendance: { attendance: { total_active_tickets: 2, checked_in_count: 1, remaining_count: 1, check_in_rate: 50, timezone: 'Pacific/Guam',
    by_ticket_type: [{ ticket_type_id: 14, ticket_type_name: 'Alumni', total_active_tickets: 2, checked_in_count: 1, check_in_rate: 50 }],
    pace: [{ bucket_start: '2026-11-23T18:30:00+10:00', label: '6:30 PM', count: 1 }],
  } },
  demographics: { demographics: [{
    question_id: 92, kind: 'number', scope: 'ticket', prompt: 'Graduation Year', total_responses: 2, blank_or_unanswered_count: 0,
    buckets: [{ value: 1998, label: '1998', count: 1, percentage: 50 }, { value: 2027, label: '2027', count: 1, percentage: 50 }],
  }] },
  payouts: { payout_series: [{ id: 23, name: 'Tournament Series' }] },
}
const roster = {
  attendees: [{ id: 7, attendee_name: 'Sample Attendee', buyer_name: 'Sample Buyer', ticket_type: 'Alumni',
    order_status_label: 'Paid', status: 'checked_in', pricing_tier: 'Early Bird',
    registration_answers: [{ question_id: 92, prompt: 'Graduation Year', value: 1998 }] }],
  registration_questions: [{ question_id: 92, prompt: 'Graduation Year', kind: 'number' }],
  meta: { total_count: 1, total_pages: 1, current_page: 1 },
}

function Location() {
  const { search } = useLocation()
  return <output data-testid="location">{search}</output>
}

function mount(search = '') {
  return render(<MemoryRouter initialEntries={[path + search]}>
    <Routes><Route path="/dashboard/events/:id/reports" element={<><EventReportsPage /><Location /></>} /></Routes>
  </MemoryRouter>)
}

function setup({ permissions = event.permissions, overrides = {} } = {}) {
  apiClient.get.mockImplementation((url, config) => {
    if (url === base) return Promise.resolve({ data: { ...event, permissions } })
    if (url.endsWith('/export.csv')) return Promise.resolve({ data: new Blob(['\uFEFFcsv']) })
    if (url.endsWith('/attendees')) return Promise.resolve({ data: overrides.roster || roster })
    if (url.endsWith('/reports')) return Promise.resolve({ data: overrides[config.params.report_type] || responses[config.params.report_type] })
    throw new Error(`Unexpected route ${url}`)
  })
}

const currentParams = () => new URLSearchParams(screen.getByTestId('location').textContent)
const nav = () => within(screen.getByRole('navigation', { name: 'Report views' }))

describe('EventReportsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.restoreAllMocks()
    localStorage.clear()
    setup()
  })

  it('shows all five views and preserves the existing payout and series links', async () => {
    mount()
    expect(await screen.findByRole('cell', { name: /Early Bird/ })).toBeInTheDocument()
    expect(screen.getAllByText('$40.00')[0]).toBeInTheDocument()
    expect(nav().getAllByRole('link')).toHaveLength(5)

    await userEvent.click(nav().getByRole('link', { name: 'Attendance & Door Pace' }))
    expect(await screen.findByText('6:30 PM')).toBeInTheDocument()
    expect(screen.getByText(/Pacific\/Guam/)).toBeInTheDocument()
    expect(currentParams().get('tab')).toBe('attendance')

    await userEvent.click(nav().getByRole('link', { name: 'Attendee Answers & Sizes' }))
    expect(await screen.findByRole('heading', { name: 'Graduation Year' })).toBeInTheDocument()

    await userEvent.click(nav().getByRole('link', { name: 'Registrations & Teams' }))
    expect(await screen.findByRole('rowheader', { name: 'Sample Attendee' })).toBeInTheDocument()
    expect(screen.getByRole('cell', { name: 'Sample Buyer' })).toBeInTheDocument()

    await userEvent.click(nav().getByRole('link', { name: 'Payouts & Splits' }))
    expect(await screen.findByRole('link', { name: 'Open payout & statement' })).toHaveAttribute('href', '/dashboard/events/37/analytics#settlement')
    expect(screen.getByRole('link', { name: 'Tournament Series report' })).toHaveAttribute('href', '/dashboard/series/23/report')
  })

  it('drills down from a bar and keeps the shared filters on reload and in CSV downloads', async () => {
    const user = userEvent.setup()
    const view = mount('?tab=demographics&ticket_type_id=14&channel=box_office')
    const bar = await screen.findByRole('link', { name: /Show registrations for Graduation Year: 1998/ })
    await user.click(bar)
    const remove = await screen.findByRole('button', { name: 'Remove filter Graduation Year · 1998' })
    expect(remove).toBeInTheDocument()
    expect(screen.getByRole('cell', { name: '1998' })).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith(`${base}/attendees`, expect.objectContaining({
      params: { active_only: 'true', page: '1', ticket_type_id: '14', channel: 'box_office', question_id: '92', answer_value: '1998' },
    }))
    const search = screen.getByTestId('location').textContent
    expect(currentParams().get('tab')).toBe('registrations')
    view.unmount()
    mount(search)
    expect(await screen.findByRole('button', { name: 'Remove filter Graduation Year · 1998' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Download CSV' }))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(expect.any(Blob), 'community-night-registrations-roster.csv'))
    expect(apiClient.get).toHaveBeenCalledWith(`${base}/reports/export.csv`, expect.objectContaining({
      responseType: 'blob', params: { ticket_type_id: '14', channel: 'box_office', question_id: '92', answer_value: '1998',
        report_type: 'registrations_roster' },
    }))
    await user.click(screen.getByRole('button', { name: /Remove filter Graduation Year/ }))
    expect(currentParams().has('question_id')).toBe(false)
    expect(currentParams().has('answer_value')).toBe(false)
    expect(currentParams().get('ticket_type_id')).toBe('14')
    const searchBox = screen.getByRole('searchbox', { name: 'Search registrations' })
    await user.type(searchBox, 'Sample')
    await user.click(screen.getByRole('button', { name: 'Search', exact: true }))
    expect(currentParams().get('search')).toBe('Sample')
  })

  it('keeps a tab change when a filter is used before the router renders the new URL', async () => {
    mount('?tab=attendance')
    await screen.findByText('6:30 PM')
    window.history.replaceState(null, '', path + '?tab=demographics')
    try {
      await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Ticket type' }), '14')
      expect(await screen.findByRole('heading', { name: 'Graduation Year' })).toBeInTheDocument()
      expect(currentParams().get('tab')).toBe('demographics')
      expect(currentParams().get('ticket_type_id')).toBe('14')
    } finally {
      window.history.replaceState(null, '', '/')
    }
  })

  it('prints the selected report and handles an empty sales report', async () => {
    setup({ overrides: { sales_by_tier: { summary: kpis, sales_by_tier: [] } } })
    const print = vi.spyOn(window, 'print').mockImplementation(() => {})
    mount('?tab=sales')
    expect(await screen.findByText('No ticket sales match these filters.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Print Report' }))
    expect(print).toHaveBeenCalledOnce()
  })

  it('keeps stale rows and export actions out of the error state and can retry', async () => {
    apiClient.get.mockImplementationOnce(() => Promise.resolve({ data: event }))
    apiClient.get.mockRejectedValueOnce({ response: { status: 500 } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('This report could not be loaded.')
    expect(screen.queryByRole('button', { name: 'Download CSV' })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByRole('cell', { name: /Early Bird/ })).toBeInTheDocument()
  })

  it('shows only the views allowed by the event permission map', async () => {
    setup({ permissions: { view_attendees: true } })
    mount('?tab=sales')
    expect(await screen.findByText('6:30 PM')).toBeInTheDocument()
    expect(nav().queryByRole('link', { name: 'Sales by Price Window' })).not.toBeInTheDocument()
    expect(nav().queryByRole('link', { name: 'Payouts & Splits' })).not.toBeInTheDocument()
    expect(apiClient.get).not.toHaveBeenCalledWith(`${base}/reports`, expect.objectContaining({ params: { report_type: 'sales_by_tier' } }))
  })
})
