import { MemoryRouter } from 'react-router-dom'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import ProviderReadinessPage from './ProviderReadinessPage'

vi.mock('../../api/client', async original => ({ ...await original(),
  default: { get: vi.fn(), post: vi.fn() },
}))

vi.mock('./AdminLayout', () => ({
  default: ({ children }) => <div>{children}</div>,
}))

describe('ProviderReadinessPage', () => {
  const capability = {
    capability: 'policy_register', label: 'Production policy register', configured: true,
    approved: false, enabled: false, status: 'disabled_pending_approval',
    required_controls: ['policy_owner_approved', 'effective_dates_approved'],
    pending_submission: null, latest_approval: null,
  }

  beforeEach(() => {
    apiClient.get.mockResolvedValue({ data: { capabilities: [capability] } })
    apiClient.post.mockResolvedValue({ data: {} })
  })

  it('approves the live policy snapshot and lists later professional-review items as information', async () => {
    apiClient.get.mockResolvedValue({ data: { capabilities: [{ ...capability,
      pending_submission: { id: 77, actor_user_id: 3, evidence_reference: 'launch-board-1' },
      policy_documents: {
        version: '2026-10-22', effective_date: '2026-10-22', status: 'approved', draft: false,
        registry_digest: 'a'.repeat(64), approval_blockers: [],
        review_notes: [{ document: 'organizer-agreement', title: 'Organizer Agreement', section: 'Tax information', note: 'Accountant to confirm tax treatment and reporting.' }],
        documents: [{ key: 'buyer-terms', title: 'Buyer Terms' }],
      } }] } })
    render(<MemoryRouter initialEntries={['/admin/provider-readiness']}><ProviderReadinessPage /></MemoryRouter>)
    expect(await screen.findByTestId('policy-register-summary')).toHaveTextContent('Effective 2026-10-22 · Version 2026-10-22 · Live')
    expect(screen.queryByTestId('policy-register-blockers')).not.toBeInTheDocument()
    expect(screen.getByTestId('policy-register-review-notes')).toHaveTextContent("Organizer Agreement · Tax information: Accountant to confirm")
    expect(screen.getByTestId('policy-register-review-notes')).toHaveTextContent("These don’t block approval")

    const approve = screen.getByRole('button', { name: 'Approve submitted evidence' })
    expect(approve).toBeEnabled()
    fireEvent.click(approve)
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_capability_reviews/77/approve',
      {}, expect.anything()))
  })

  it('shows technical blockers when the policy text cannot be approved', async () => {
    apiClient.get.mockResolvedValue({ data: { capabilities: [{ ...capability, policy_documents: {
      version: 'v', effective_date: '2026-10-22', status: 'approved', draft: false, registry_digest: 'a'.repeat(64),
      approval_blockers: ['Unfilled template placeholders remain in: Buyer Terms'], review_notes: [],
      documents: [{ key: 'buyer-terms', title: 'Buyer Terms' }],
    } }] } })
    render(<MemoryRouter initialEntries={['/admin/provider-readiness']}><ProviderReadinessPage /></MemoryRouter>)
    expect(await screen.findByTestId('policy-register-blockers')).toHaveTextContent('Unfilled template placeholders')
    expect(screen.queryByText(/draft policies/i)).not.toBeInTheDocument()
  })

  it('distinguishes configuration from independent approval and submits the exact controls', async () => {
    render(<MemoryRouter initialEntries={['/admin/provider-readiness']}><ProviderReadinessPage /></MemoryRouter>)
    await screen.findByText('Production policy register')

    expect(screen.getByText('Off until approved')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Evidence reference'), { target: { value: 'legal-register-17' } })
    fireEvent.change(screen.getByLabelText('Evidence file checksum (SHA-256)'), { target: { value: 'a'.repeat(64) } })
    fireEvent.click(screen.getByText('Policy owner approved'))
    fireEvent.click(screen.getByText('Effective dates approved'))
    fireEvent.click(screen.getByRole('button', { name: 'Submit evidence (can’t be edited later)' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/admin/platform_capabilities/policy_register/reviews',
      expect.objectContaining({
        evidence_reference: 'legal-register-17',
        evidence_digest: 'a'.repeat(64),
        controls: { policy_owner_approved: true, effective_dates_approved: true },
      }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))
  })

  it('shows that the submitting administrator cannot self-approve', async () => {
    apiClient.get.mockResolvedValue({ data: { capabilities: [{
      ...capability,
      pending_submission: { id: 91, actor_user_id: 7, evidence_reference: 'provider-report-4' },
    }] } })

    render(<MemoryRouter initialEntries={['/admin/provider-readiness']}><ProviderReadinessPage /></MemoryRouter>)

    expect(await screen.findByText(/Admin #7 submitted evidence provider-report-4/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Approve submitted evidence' })).toBeInTheDocument()
  })
})
