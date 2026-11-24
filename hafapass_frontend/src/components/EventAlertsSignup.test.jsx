import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { vi, it, expect } from 'vitest'
import EventAlertsSignup from './EventAlertsSignup'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { post: vi.fn() } }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
it('submits explicit footer consent and shows the generic confirmation notice', async () => {
  apiClient.post.mockResolvedValue({ data: { accepted: true } })
  render(<EventAlertsSignup source="footer" />)
  fireEvent.change(screen.getByLabelText('emailBase.email'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.subscribe' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/platform_subscriptions', { email: 'person@example.test', source: 'footer' }))
  expect(await screen.findByRole('status')).toHaveTextContent('emailBase.checkInbox')
})
it('keeps entered email available after failure', async () => {
  apiClient.post.mockRejectedValue(new Error('offline'))
  render(<EventAlertsSignup />)
  fireEvent.change(screen.getByLabelText('emailBase.email'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.subscribe' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('emailBase.error')
  expect(screen.getByLabelText('emailBase.email')).toHaveValue('person@example.test')
})
