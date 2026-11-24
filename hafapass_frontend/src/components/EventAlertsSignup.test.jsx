import userEvent from '@testing-library/user-event'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { vi, it, expect } from 'vitest'
import EventAlertsSignup from './EventAlertsSignup'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { post: vi.fn() } }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
it('submits explicit footer consent and shows the generic confirmation notice', async () => {
  apiClient.post.mockResolvedValue({ data: { accepted: true } })
  render(<EventAlertsSignup source="footer" />)
  fireEvent.change(screen.getByLabelText('emailBase.alertsEmail'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.subscribe' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/platform_subscriptions', { email: 'person@example.test', source: 'footer', website: '' }))
  expect(await screen.findByRole('status')).toHaveTextContent('emailBase.checkInbox')
})
it('keeps entered email available after failure', async () => {
  apiClient.post.mockRejectedValue(new Error('offline'))
  render(<EventAlertsSignup />)
  fireEvent.change(screen.getByLabelText('emailBase.alertsEmail'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.subscribe' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('emailBase.error')
  expect(screen.getByLabelText('emailBase.alertsEmail')).toHaveValue('person@example.test')
})

it('locks the submitted email during a delayed request and names it on success', async () => {
  let finish
  apiClient.post.mockImplementation(() => new Promise(resolve => { finish = resolve }))
  const user = userEvent.setup()
  render(<EventAlertsSignup />)
  const input = screen.getByLabelText('emailBase.alertsEmail')
  await user.type(input, 'sent@example.test')
  await user.click(screen.getByRole('button', { name: 'emailBase.subscribe' }))
  expect(input).toBeDisabled()
  await user.type(input, 'other@example.test')
  expect(input).toHaveValue('sent@example.test')
  expect(apiClient.post).toHaveBeenCalledWith('/platform_subscriptions', { email: 'sent@example.test', source: 'home', website: '' })
  await act(async () => finish({ data: { accepted: true } }))
  expect(await screen.findByRole('status')).toHaveTextContent('sent@example.test')
  expect(screen.getByRole('status')).not.toHaveTextContent('other@example.test')
})
