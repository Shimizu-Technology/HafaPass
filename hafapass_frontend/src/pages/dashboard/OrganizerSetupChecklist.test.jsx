import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'
import OrganizerSetupChecklist from './OrganizerSetupChecklist'

const base = {
  business_name: 'Island Nights', business_description: 'Night markets', policy_accepted: false, current_policy_version: '2026-10',
  verification_status: 'unverified', payout_ready: false, setup_progress: { events_count: 0, published_events_count: 0, payout_method: null },
}
const show = (profile = base, props = {}) => {
  const handlers = { onEditProfile: vi.fn(), onAcceptPolicy: vi.fn().mockResolvedValue(true), onSubmitVerification: vi.fn() }
  render(<MemoryRouter><OrganizerSetupChecklist profile={profile} canCreate busy={false} {...handlers} {...props} /></MemoryRouter>)
  return handlers
}

describe('OrganizerSetupChecklist', () => {
  it.each(['eBay_Events', 'island_nights'])('preserves the business name %s in the profile status', business_name => {
    show({ ...base, business_name })
    expect(screen.getByText(`${business_name} — shown on your event pages`)).toBeInTheDocument()
  })

  it('formats an unknown payout enum before composing its status', () => {
    show({ ...base, setup_progress: { ...base.setup_progress, payout_method: 'future_provider' } })
    expect(screen.getByText('Future provider saved — waiting for HåfaPass finance review')).toBeInTheDocument()
  })

  it('walks the steps in order and marks the next one', () => {
    show()
    const steps = screen.getAllByRole('listitem')
    expect(steps.map(step => step.querySelector('p').textContent.replace(/Next|\s\(done\)/g, '').trim())).toEqual([
      'Organizer profile', 'Organizer agreement', 'HåfaPass verifies your organization (tickets go on sale after this)', 'How you get paid', 'Create your first event', 'Publish',
    ])
    expect(steps[1]).toHaveAttribute('aria-current', 'step')
    expect(screen.getByText('1 of 6 done')).toBeInTheDocument()
    expect(within(steps[3]).getByRole('link', { name: 'Choose check or bank transfer' })).toHaveAttribute('href', '/dashboard/settings')
  })

  it('makes tax and payout setup conditional on selling paid tickets', () => {
    show()
    const payoutStep = screen.getAllByRole('listitem')[3]
    expect(payoutStep).toHaveTextContent('Free events can skip this.')
    expect(payoutStep).toHaveTextContent('Only needed for paid tickets: complete Tax information and How you get paid in Settings, then wait for finance approval.')
  })

  it('accepts the agreement in the shared agreement dialog, never window.confirm', async () => {
    const confirm = vi.spyOn(window, 'confirm')
    const { onAcceptPolicy } = show()
    await userEvent.click(screen.getByRole('button', { name: 'Review and accept' }))
    const dialog = within(screen.getByRole('dialog', { name: 'Accept the organizer agreement' }))
    expect(dialog.getByText(/Payouts are made by check/)).toHaveTextContent('unless another payout method has been approved')
    await userEvent.click(dialog.getByRole('button', { name: 'Accept version 2026-10' }))
    expect(onAcceptPolicy).toHaveBeenCalled()
    expect(confirm).not.toHaveBeenCalled()
  })

  it('clears a stale error when the agreement dialog opens and shows a new error only inside it', async () => {
    const onOpenAgreement = vi.fn()
    const { rerender } = render(<MemoryRouter><OrganizerSetupChecklist profile={base} canCreate busy={false} onOpenAgreement={onOpenAgreement} onAcceptPolicy={vi.fn()} /></MemoryRouter>)
    await userEvent.click(screen.getByRole('button', { name: 'Review and accept' }))
    expect(onOpenAgreement).toHaveBeenCalled()
    rerender(<MemoryRouter><OrganizerSetupChecklist profile={base} canCreate busy={false} agreementError="Agreement could not be saved" onOpenAgreement={onOpenAgreement} onAcceptPolicy={vi.fn()} /></MemoryRouter>)
    expect(screen.getAllByText('Agreement could not be saved')).toHaveLength(1)
    expect(within(screen.getByRole('dialog')).getByRole('alert')).toHaveTextContent('Agreement could not be saved')
  })

  it('flags an updated agreement that needs re-acceptance', () => {
    show({ ...base, policy_version: '2026-07' })
    expect(screen.getByTestId('agreement-update-notice')).toHaveTextContent('updated to version 2026-10')
  })

  it('explains what HåfaPass does next while verification and payouts are under review', () => {
    show({ ...base, policy_accepted: true, verification_status: 'pending', setup_progress: { ...base.setup_progress, payout_method: 'check' } })
    expect(screen.getByText('Submitted — HåfaPass is reviewing it')).toBeInTheDocument()
    expect(screen.getByText('Check saved — waiting for HåfaPass finance review')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Submit for review' })).not.toBeInTheDocument()
  })

  it('labels a suspended organizer without offering a private preview', () => {
    show({ ...base, policy_accepted: true, verification_status: 'suspended',
      setup_progress: { events_count: 1, published_events_count: 1, payout_method: null } })
    const publish = screen.getAllByRole('listitem').find(item => item.textContent.includes('Publish'))
    expect(publish).toHaveTextContent('Hidden while suspended')
    expect(publish).not.toHaveTextContent('private preview')
    expect(screen.getByText('HåfaPass verifies your organization (tickets go on sale after this)').closest('li')).not.toHaveTextContent('Next')
  })

  it('uses one verification action and explains private previews to new organizers', async () => {
    const { onSubmitVerification } = show({ ...base, policy_accepted: true })
    expect(screen.getByText("Start a draft. When you publish, you'll get a private preview link; it goes public once you're verified.")).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Request verification' }))
    expect(onSubmitVerification).toHaveBeenCalledOnce()
  })

  it('lets an organizer open the request form to add a missing description', () => {
    show({ ...base, business_description: '', policy_accepted: true })
    expect(screen.getByRole('button', { name: 'Request verification' })).toBeEnabled()
    expect(screen.getByText('Add a short description in the request form.')).toBeInTheDocument()
  })

  it('shows status only to an admin viewing the workspace', () => {
    show(base, { adminView: true })
    expect(screen.getByText(/Only the owner can accept the agreement/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Review and accept' })).not.toBeInTheDocument()
  })

  it('disappears once everything is done', () => {
    const { container } = render(<MemoryRouter><OrganizerSetupChecklist canCreate busy={false} profile={{ ...base, policy_accepted: true, verification_status: 'verified', payout_ready: true,
      setup_progress: { events_count: 2, published_events_count: 1, payout_method: 'check' } }} /></MemoryRouter>)
    expect(container).toBeEmptyDOMElement()
  })
})
