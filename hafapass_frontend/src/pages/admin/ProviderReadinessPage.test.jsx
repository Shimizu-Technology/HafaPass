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
    required_controls: ['counsel_approved', 'privacy_approved'],
    pending_submission: null, latest_approval: null,
  }

  beforeEach(() => {
    apiClient.get.mockResolvedValue({ data: { capabilities: [capability] } })
    apiClient.post.mockResolvedValue({ data: {} })
  })

  it('distinguishes configuration from independent approval and submits the exact controls', async () => {
    render(<MemoryRouter initialEntries={['/admin/provider-readiness']}><ProviderReadinessPage /></MemoryRouter>)
    await screen.findByText('Production policy register')

    expect(screen.getByText('Off until approved')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Evidence reference'), { target: { value: 'legal-register-17' } })
    fireEvent.change(screen.getByLabelText('SHA-256 evidence digest'), { target: { value: 'a'.repeat(64) } })
    fireEvent.click(screen.getByText('Legal counsel approved'))
    fireEvent.click(screen.getByText('Privacy review approved'))
    fireEvent.click(screen.getByRole('button', { name: 'Submit evidence (can’t be edited later)' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/admin/platform_capabilities/policy_register/reviews',
      expect.objectContaining({
        evidence_reference: 'legal-register-17',
        evidence_digest: 'a'.repeat(64),
        controls: { counsel_approved: true, privacy_approved: true },
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
    expect(screen.getByRole('button', { name: 'Approve exact snapshot' })).toBeInTheDocument()
  })
})
