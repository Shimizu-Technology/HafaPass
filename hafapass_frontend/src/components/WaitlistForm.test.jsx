import { expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import WaitlistForm from './WaitlistForm'

vi.mock('../api/client', () => ({ default: { post: vi.fn(), get: vi.fn(), delete: vi.fn() } }))

it('states the event-specific email request and exit clearly at join', () => {
  render(<WaitlistForm event={{ slug: 'friday-show' }} />)
  expect(screen.getByText("We'll email you if tickets become available for this event. You can stop these alerts anytime.")).toBeInTheDocument()
})

import { beforeEach } from 'vitest'
import userEvent from '@testing-library/user-event'
import api from '../api/client'
beforeEach(() => { window.localStorage.clear(); api.get.mockReset() })
it('describes browser-saved credentials, not an email-wide search', async () => {
  render(<WaitlistForm event={{ slug: 'friday-show' }} />)
  await userEvent.type(screen.getByPlaceholderText('Enter your email'), 'buyer@example.test')
  await userEvent.click(screen.getByRole('button', { name: 'Check' }))
  expect(await screen.findByText(/No waitlist entries are saved in this browser for this email/)).toBeInTheDocument()
  expect(api.get).not.toHaveBeenCalled()
})
it('reports failed checks separately and retries saved credentials with readable statuses', async () => {
  window.localStorage.setItem('hafapass:waitlist:friday-show:buyer@example.test', JSON.stringify([{ id: 1, token: 'saved-token' }]))
  api.get.mockRejectedValueOnce(new Error('offline')).mockResolvedValue({ data: { entries: ['notified', 'offered', 'converted', 'expired'].map((status, id) => ({ id, position: id + 1, status })) } })
  render(<WaitlistForm event={{ slug: 'friday-show' }} />)
  await userEvent.type(screen.getByPlaceholderText('Enter your email'), 'buyer@example.test')
  await userEvent.click(screen.getByRole('button', { name: 'Check' }))
  expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't check your saved waitlist entries.")
  expect(screen.queryByText(/No waitlist entries/)).not.toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Check' }))
  for (const label of ['Availability email sent', 'Ticket offer available', 'Tickets claimed', 'Offer expired']) expect(await screen.findByText(label)).toBeInTheDocument()
})
