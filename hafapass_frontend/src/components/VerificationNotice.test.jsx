import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, it, vi } from 'vitest'
import VerificationNotice from './VerificationNotice'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { post: vi.fn() } }))
const profile = { business_name: 'Island Events', business_description: 'Community shows',
  verification_status: 'unverified', organization: { role: 'owner' } }
const beginRequest = () => ({ config: {}, current: () => true, release: () => {} })
beforeEach(() => vi.clearAllMocks())

it.each([
  ['unverified', 'Get verified to start selling tickets'],
  ['pending', "We're reviewing your account"],
  ['rejected', 'Your verification needs an update'],
  ['suspended', 'Your organizer account is suspended'],
  ['verified', 'Your organizer account is verified'],
])('explains the %s state', (status, title) => {
  render(<VerificationNotice profile={{ ...profile, verification_status: status,
    verification_requested_at: '2026-10-23T00:00:00Z', verification_notes: 'Add a website.' }} beginRequest={beginRequest} />)
  expect(screen.getByRole('heading', { name: title })).toBeInTheDocument()
  if (status === 'rejected') expect(screen.getByText('Add a website.')).toBeInTheDocument()
})

it('validates inline, retains entered fields, then submits the fixed request', async () => {
  const user = userEvent.setup()
  apiClient.post.mockResolvedValue({ data: { ...profile, verification_status: 'pending' } })
  render(<VerificationNotice profile={profile} beginRequest={beginRequest} />)
  await user.click(screen.getByRole('button', { name: 'Request verification' }))
  await user.type(screen.getByRole('textbox', { name: /Contact phone/ }), '123')
  await user.type(screen.getByRole('textbox', { name: /Website or social media link/ }), 'invalid')
  await user.click(screen.getByRole('button', { name: 'Send request' }))
  expect(screen.getAllByRole('alert').length).toBeGreaterThan(0)
  expect(screen.getByRole('textbox', { name: /Contact phone/ })).toHaveFocus()
  expect(screen.getByText(/Check 2 highlighted verification fields/)).toHaveAttribute('aria-live', 'assertive')
  expect(apiClient.post).not.toHaveBeenCalled()
  expect(screen.getByRole('textbox', { name: /Contact phone/ })).toHaveValue('123')
  await user.clear(screen.getByRole('textbox', { name: /Contact phone/ }))
  await user.type(screen.getByRole('textbox', { name: /Contact phone/ }), '+1-671-555-1234')
  await user.clear(screen.getByRole('textbox', { name: /Website or social media link/ }))
  await user.type(screen.getByRole('textbox', { name: /Website or social media link/ }), 'https://instagram.com/islandevents')
  await user.click(screen.getByRole('button', { name: 'Send request' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer_profile/submit_verification', expect.objectContaining({
    business_name: 'Island Events', business_description: 'Community shows', verification_phone: '+1-671-555-1234',
    verification_link: 'https://instagram.com/islandevents',
  }), {})
  expect(await screen.findByRole('heading', { name: "We're reviewing your account" })).toBeInTheDocument()
})
