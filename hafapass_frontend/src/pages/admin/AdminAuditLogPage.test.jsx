import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminAuditLogPage from './AdminAuditLogPage'
import { auditChanges } from './adminOperations'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const entry = {
  id: 31, action: 'site_settings.fee_terms_updated', occurred_at: '2026-10-20T01:00:00Z',
  actor: { id: 1, email: 'leon@example.com', name: 'Leon Shimizu' }, target: { type: 'SiteSetting', id: 1 }, organization: null,
  before_data: { service_fee_percent: '3.0', service_fee_flat_cents: '50' }, after_data: { service_fee_percent: '5.0', service_fee_flat_cents: '50' },
  metadata: { source: 'admin' }, request_id: 'req-1',
}

describe('AdminAuditLogPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: { audit_logs: [entry], meta: { page: 1, total_pages: 3, total_count: 60 }, areas: ['payout', 'site_settings'] } })
  })

  it('summarizes each entry and shows only changed fields in its details', async () => {
    const user = userEvent.setup()
    render(<MemoryRouter initialEntries={['/admin/audit-log']}><AdminAuditLogPage /></MemoryRouter>)
    expect(await screen.findByText('Site settings: Fee terms updated')).toBeInTheDocument()
    expect(screen.getByText(/1 field changed/)).toBeInTheDocument()
    expect(screen.getByText('Leon Shimizu (leon@example.com)')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Details for entry 31' }))
    expect(screen.getByText('service_fee_percent')).toBeInTheDocument()
    expect(screen.queryByText('service_fee_flat_cents')).not.toBeInTheDocument()
    expect(screen.getByText(/request req-1/)).toBeInTheDocument()
  })

  it('searches, filters by area and paginates through the URL-backed filters', async () => {
    const user = userEvent.setup()
    render(<MemoryRouter initialEntries={['/admin/audit-log?target_type=Event&target_id=4']}><AdminAuditLogPage /></MemoryRouter>)
    expect(await screen.findByText('Showing entries for Event #4')).toBeInTheDocument()
    await user.type(screen.getByRole('searchbox', { name: 'Search the audit log' }), 'payout')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/audit_logs', expect.objectContaining({ params: { q: 'payout', target_type: 'Event', target_id: '4', page: 1 } })))
    await user.selectOptions(screen.getByLabelText('Area'), 'payout')
    await user.click(await screen.findByRole('button', { name: 'Next' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/audit_logs', expect.objectContaining({ params: expect.objectContaining({ area: 'payout', page: '2' }) })))
  })

  it('lists every field recorded for a creation', () => {
    expect(auditChanges({}, { kind: 'manual_credit', amount_cents: 500 })).toEqual([
      { key: 'kind', before: undefined, after: 'manual_credit' }, { key: 'amount_cents', before: undefined, after: 500 },
    ])
  })
})
