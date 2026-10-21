import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { saveBlob } from '../../utils/download'
import AdminTaxReportsPage from './AdminTaxReportsPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
const year = new Date().getFullYear()
const report = { year, note: "HåfaPass's gross receipts are its service fees; ticket proceeds belong to organizers (agent model). Confirm with your accountant.", organizers: [{ organization_id: 7, organization_name: 'Island Events', w9_on_file: true, gross_ticket_proceeds_cents: 2500, refunds_cents: 500, fees_collected_cents: 225, fees_refunded_cents: 100, net_paid_cents: 1700, tax_information: { legal_name: 'Island Events LLC', tax_classification: 'llc_c', masked_tin: '***-**-5678' } }], months: [{ month: 1, fees_collected_cents: 225, fees_refunded_cents: 100, gross_receipts_cents: 125, card_processing_costs_cents: 80 }] }
const show = () => render(<MemoryRouter initialEntries={['/admin/tax-reports']}><AdminTaxReportsPage /></MemoryRouter>)

describe('AdminTaxReportsPage', () => {
  beforeEach(() => { vi.clearAllMocks(); apiClient.get.mockResolvedValue({ data: report }) })

  it('shows masked identities, live-only definitions, and the accountant note', async () => {
    show()
    expect(await screen.findByText('***-**-5678')).toBeInTheDocument()
    expect(screen.getByText(/Live-mode USD payments only/)).toBeInTheDocument()
    expect(screen.getByText(report.note)).toBeInTheDocument()
    expect(screen.getByText('$1.25')).toBeInTheDocument()
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Calendar year'), String(year - 1))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/tax_reports', expect.objectContaining({ params: { year: String(year - 1) } })))
  })

  it('uses an explicit POST to reveal, hides on demand and never includes TIN in the request', async () => {
    apiClient.post.mockResolvedValue({ data: { tin: '012345678' } })
    show()
    await userEvent.click(await screen.findByRole('button', { name: 'Reveal TIN for Island Events' }))
    expect(await screen.findByText('012345678')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/admin/organizations/7/tax_information/reveal', { year }, expect.anything())
    await userEvent.click(screen.getByRole('button', { name: 'Hide TIN for Island Events' }))
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
    expect(screen.getByText('***-**-5678')).toBeInTheDocument()
  })

  it('downloads masked CSV by GET and explicitly labelled 1099 CSV by audited POST', async () => {
    const blob = new Blob(['fixture'], { type: 'text/csv' })
    show()
    await screen.findByText('***-**-5678')
    apiClient.get.mockResolvedValue({ data: blob })
    apiClient.post.mockResolvedValue({ data: blob })
    await userEvent.click(screen.getByRole('button', { name: 'Export masked CSV' }))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(blob, `hafapass-organizers_export-${year}.csv`))
    await userEvent.click(screen.getByRole('button', { name: 'Export full TINs for 1099 preparation (audited)' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/tax_reports/preparation_export', { year }, expect.objectContaining({ responseType: 'blob' })))
    await userEvent.click(screen.getByRole('button', { name: 'Export gross receipts CSV' }))
    expect(apiClient.get).toHaveBeenLastCalledWith('/admin/tax_reports/receipts_export', expect.objectContaining({ responseType: 'blob' }))
  })

  it('shows recovery for failures and handles an empty report', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline'))
    show()
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not load tax reports')
    apiClient.get.mockResolvedValue({ data: { ...report, organizers: [] } })
    await userEvent.click(screen.getByRole('button', { name: 'Retry reports' }))
    expect(await screen.findByText('No live financial activity for this year.')).toBeInTheDocument()
  })
})
