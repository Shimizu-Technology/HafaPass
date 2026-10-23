import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import TaxInformationSection from './TaxInformationSection'

const certification = 'Under penalties of perjury, I certify that my TIN is correct.'
const saved = { legal_name: 'Island Events', tax_classification: 'llc_c', tin_type: 'ein', mailing_address: 'PO Box 1', signer_name: 'Alex Owner', masked_tin: '***-**-5678', certified_at: '2026-10-21T00:00:00Z', w9_on_file: true }
const respond = (tax = null, locked = false) => vi.fn().mockResolvedValue({ data: { tax_information: tax, edit_locked: locked, certification } })

describe('TaxInformationSection', () => {
  it('collects a separate certification and signature, reuses check address, and clears the full TIN after saving', async () => {
    const request = respond()
    request.mockImplementation((method) => Promise.resolve({ data: { tax_information: method === 'patch' ? saved : null, certification, edit_locked: false } }))
    const onSaved = vi.fn()
    render(<TaxInformationSection request={request} mailingAddress="PO Box 1" onSaved={onSaved} />)
    await userEvent.click(await screen.findByRole('button', { name: 'Add tax information' }))
    fireEvent.change(screen.getByLabelText('Legal name'), { target: { value: 'Island Events' } })
    await userEvent.selectOptions(screen.getByLabelText('Federal tax classification'), 'llc_c')
    fireEvent.change(screen.getByLabelText('Taxpayer identification number (9 digits)'), { target: { value: '012345678' } })
    await userEvent.click(screen.getByRole('button', { name: 'Use check mailing address' }))
    expect(screen.getByLabelText('Tax mailing address')).toHaveValue('PO Box 1')
    expect(screen.getByLabelText('Taxpayer ID type')).toHaveValue('ein')
    expect(screen.getByRole('option', { name: 'Employer identification number (EIN)' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Social Security number (SSN)' })).toBeInTheDocument()
    expect(screen.getByText(/Before publishing a paid event/)).toHaveTextContent('complete and certify your W-9 and get your payout method approved')
    await userEvent.click(screen.getByRole('checkbox'))
    fireEvent.change(screen.getByLabelText('Signer’s typed name'), { target: { value: 'Alex Owner' } })
    await userEvent.click(screen.getByRole('button', { name: 'Sign and save tax information' }))
    await waitFor(() => expect(request).toHaveBeenCalledWith('patch', '/organizer/tax_information', { tax_information: expect.objectContaining({ tin: '012345678', certified: true, signer_name: 'Alex Owner', mailing_address: 'PO Box 1' }) }))
    expect(await screen.findByText(/Island Events · \*\*\*-\*\*-5678/)).toBeInTheDocument()
    expect(screen.queryByDisplayValue('012345678')).not.toBeInTheDocument()
    expect(onSaved).toHaveBeenCalledOnce()
    await userEvent.click(screen.getByRole('button', { name: 'Change tax information' }))
    expect(screen.getByLabelText('Taxpayer identification number (9 digits)')).toHaveValue('')
    expect(screen.getByRole('checkbox')).not.toBeChecked()
  })

  it('shows masked saved identity and disables editing while any payout is unresolved', async () => {
    render(<TaxInformationSection request={respond(saved, true)} />)
    expect(await screen.findByRole('button', { name: 'Change tax information' })).toBeDisabled()
    expect(screen.getByRole('status')).toHaveTextContent('payout is pending, in progress or on hold')
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
  })

  it('validates nine digits, surfaces save errors and allows cancelling without retaining the TIN', async () => {
    const request = respond()
    render(<TaxInformationSection request={request} />)
    await userEvent.click(await screen.findByRole('button', { name: 'Add tax information' }))
    const form = screen.getByRole('button', { name: 'Sign and save tax information' }).closest('form')
    fireEvent.submit(form)
    expect(screen.getByRole('alert')).toHaveTextContent('9-digit taxpayer identification number')
    request.mockRejectedValueOnce({ response: { data: { error: 'A payout is pending, in progress or on hold.' } } })
    fireEvent.change(screen.getByLabelText('Taxpayer identification number (9 digits)'), { target: { value: '012345678' } })
    fireEvent.submit(form)
    expect(await screen.findByRole('alert')).toHaveTextContent('payout is pending, in progress or on hold')
    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await userEvent.click(screen.getByRole('button', { name: 'Add tax information' }))
    expect(screen.getByLabelText('Taxpayer identification number (9 digits)')).toHaveValue('')
  })

  it('offers load recovery without an unverified edit form', async () => {
    render(<TaxInformationSection request={vi.fn().mockRejectedValue(new Error('offline'))} />)
    expect(await screen.findByRole('alert')).toHaveTextContent('Reload settings to retry')
    expect(screen.queryByRole('button', { name: 'Add tax information' })).not.toBeInTheDocument()
  })
})
