import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { saveBlob } from '../../utils/download'
import AdminTaxControlsPage from './AdminTaxControlsPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn() } }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const year = new Date().getFullYear()
const matching = { payees: [{ organization_id: 7, organization_name: 'Island Events', tax_information: {
  legal_name: 'Island Events LLC', masked_tin: '***-**-5678', tin_match_status: 'mismatch',
  backup_withholding_required: false, backup_withholding_flag: false, tin_type: 'ein',
} }] }
const annual = { reports: [{ organization_id: 7, payee_key: 'payee-key', organization_name: 'Island Events', masked_tin: '***-**-5678',
  gross_paid_cents: 10003, withheld_cents: 2401, refund_clawbacks_cents: 500,
  form_type: 'review_required', jurisdiction: 'irs', reporting_status: 'cpa_review' }] }

describe('AdminTaxControlsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/admin/tin_matching' ? matching : annual }))
    apiClient.post.mockResolvedValue({ data: new Blob(['fixture']) })
    apiClient.patch.mockResolvedValue({ data: {} })
  })

  const show = () => render(<MemoryRouter initialEntries={['/admin/tax-controls']}><AdminTaxControlsPage /></MemoryRouter>)

  it('shows masked statuses and money, and changes annual form and jurisdiction', async () => {
    show()
    expect(await screen.findAllByText(/\*\*\*-\*\*-5678/)).not.toHaveLength(0)
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
    expect(screen.getByText(/Gross paid \$100\.03 · Withheld \$24\.01/)).toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Form type'), '1099-misc')
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/annual_tax_reports/7',
      { year: String(year), payee_key: 'payee-key', form_type: '1099-misc', jurisdiction: 'irs' }, expect.anything()))
    await userEvent.selectOptions(screen.getByLabelText('Filing jurisdiction'), 'guam_drt')
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/annual_tax_reports/7',
      { year: String(year), payee_key: 'payee-key', form_type: 'review_required', jurisdiction: 'guam_drt' }, expect.anything()))
  })

  it('requires purpose and confirmation for a sensitive matching file, then imports a result', async () => {
    show()
    await screen.findByText(/TIN status:/)
    const prompt = vi.spyOn(window, 'prompt').mockReturnValue('IRS matching review')
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    await userEvent.click(screen.getByRole('button', { name: 'Export verification file' }))
    expect(apiClient.post).not.toHaveBeenCalled()
    confirm.mockReturnValue(true)
    await userEvent.click(screen.getByRole('button', { name: 'Export verification file' }))
    expect(prompt).toHaveBeenCalled()
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('full taxpayer identification numbers'))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/tin_matching/export',
      { purpose: 'IRS matching review', confirm_full_tins: true }, expect.anything()))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(expect.any(Blob), expect.stringContaining('SENSITIVE-FULL-TINS.txt')))
    await userEvent.upload(screen.getByLabelText('IRS result file'), new File(['1;012345678;Island Events;abc;0'], 'result.txt', { type: 'text/plain' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/tin_matching/import', expect.any(FormData), expect.anything()))
    vi.restoreAllMocks()
  })

  it('records IRS receipt before a B-notice can be sent', async () => {
    show()
    await screen.findByText(/TIN status:/)
    expect(screen.getByRole('button', { name: /Record .* notice sent today/ })).toBeDisabled()
    await userEvent.type(screen.getByLabelText('IRS notice receipt date'), '2026-10-01')
    await userEvent.click(screen.getByRole('button', { name: 'Record IRS notice receipt' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/organizations/7/tax_information/notice_received',
      { received_on: '2026-10-01' }, expect.anything()))
  })

  it('offers second-notice validation even after a later bulk match reports matched', async () => {
    const pendingSecondNotice = { payees: [{ ...matching.payees[0], tax_information: {
      ...matching.payees[0].tax_information, tin_match_status: 'matched', b_notice_stage: 'second',
      irs_validation_recorded_on: null,
    } }] }
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/admin/tin_matching' ? pendingSecondNotice : annual }))
    show()
    expect(await screen.findByRole('button', { name: 'Record IRS Letter 147C validation' })).toBeInTheDocument()
  })

  it('asks for a purpose and confirmation before exporting full TINs', async () => {
    show()
    await screen.findByText(/TIN status:/)
    vi.spyOn(window, 'prompt').mockReturnValue('CPA filing preparation')
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    await userEvent.click(screen.getByRole('button', { name: 'Export full TINs' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/annual_tax_reports/export',
      { year: String(year), include_full_tins: true, purpose: 'CPA filing preparation' }, expect.anything()))
    vi.restoreAllMocks()
  })

  it('requires a reason for a manual withholding flag', async () => {
    show()
    await screen.findByText(/TIN status:/)
    const button = screen.getByRole('button', { name: 'Flag for withholding' })
    expect(button).toBeDisabled()
    await userEvent.type(screen.getByLabelText('Reason for flag change'), 'CPA notice confirmed')
    await userEvent.click(button)
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizations/7/tax_information/withholding_flag',
      { flagged: true, reason: 'CPA notice confirmed' }, expect.anything()))
  })
})
