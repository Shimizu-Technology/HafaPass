import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import VerificationNotice from './VerificationNotice'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { post: vi.fn(), get: vi.fn(() => Promise.resolve({ data: {} })) } }))

const config = { organizationId: '1' }
const beginRequest = () => ({ config, current: () => true, release: () => {} })
const owner = { organization: { role: 'owner' } }

beforeEach(() => { vi.clearAllMocks(); vi.stubEnv('VITE_SUPPORT_EMAIL', 'help@example.test') })

describe('VerificationNotice', () => {
  it('lets the owner request verification and confirms when it was requested', async () => {
    const user = userEvent.setup()
    const onUpdated = vi.fn()
    const profile = { ...owner, verification_status: 'pending', verification_requested_at: '2026-10-21T00:30:00Z' }
    apiClient.post.mockResolvedValue({ data: profile })
    render(<VerificationNotice profile={{ ...owner, verification_status: 'unverified' }} beginRequest={beginRequest} onUpdated={onUpdated} />)
    expect(screen.getByText('Waiting for HåfaPass to verify your organization before tickets go on sale.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Request verification' }))
    expect(apiClient.post).toHaveBeenCalledWith('/organizer_profile/submit_verification', {}, config)
    expect(await screen.findByText(/^Verification requested .*2026.*\. HåfaPass will review it soon\.$/)).toBeInTheDocument()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
    expect(onUpdated).toHaveBeenCalledWith(profile)
  })

  it('shows the server reason when the request is refused', async () => {
    const user = userEvent.setup()
    apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'Add a business description first.' } } })
    render(<VerificationNotice profile={{ ...owner, verification_status: 'unverified' }} beginRequest={beginRequest} />)
    await user.click(screen.getByRole('button', { name: 'Request verification' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Add a business description first.')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Request verification' })).toBeEnabled())
  })

  it('shows review notes after a rejection and lets the owner ask again', () => {
    render(<VerificationNotice profile={{ ...owner, verification_status: 'rejected', verification_notes: 'Business name does not match.' }} beginRequest={beginRequest} />)
    expect(screen.getByText('Business name does not match.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Request verification' })).toBeInTheDocument()
  })

  it('explains a pause with the note and a way to contact HåfaPass, with no request button', async () => {
    render(<VerificationNotice profile={{ ...owner, verification_status: 'suspended', verification_notes: 'Refund complaints.' }} beginRequest={beginRequest} />)
    expect(screen.getByText('HåfaPass paused sales for your organization.')).toBeInTheDocument()
    expect(screen.getByText('Refund complaints.')).toBeInTheDocument()
    expect(await screen.findByRole('link', { name: 'Contact HåfaPass' })).toHaveAttribute('href', expect.stringContaining('mailto:'))
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })

  it('tells team members who cannot request it who can', () => {
    render(<VerificationNotice profile={{ organization: { role: 'manager' }, verification_status: 'unverified' }} beginRequest={beginRequest} />)
    expect(screen.getByText('Ask the organization owner to request verification.')).toBeInTheDocument()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })

  it('renders nothing once verified', () => {
    const { container } = render(<VerificationNotice profile={{ ...owner, verification_status: 'verified' }} beginRequest={beginRequest} />)
    expect(container).toBeEmptyDOMElement()
  })
})
