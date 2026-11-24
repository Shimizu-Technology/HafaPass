import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import { vi, it, expect } from 'vitest'
import EmailPreferencesPage from './EmailPreferencesPage'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), patch: vi.fn() } }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
const show = confirm => render(<MemoryRouter initialEntries={['/preferences/token']}><Routes><Route path="/preferences/:token" element={<EmailPreferencesPage confirm={confirm} />} /></Routes></MemoryRouter>)
it('requires an affirmative confirmation click', async () => {
  apiClient.post.mockResolvedValue({ data: { confirmed: true } })
  show(true)
  expect(apiClient.post).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.confirm' }))
  expect(await screen.findByRole('status')).toHaveTextContent('emailBase.confirmed')
})
it('shows scoped choices and sends unsubscribe all explicitly', async () => {
  apiClient.get.mockResolvedValue({ data: { platform: true, organizers: [{ id: 8, name: 'Organizer', enabled: false }] } })
  apiClient.patch.mockResolvedValue({ data: { platform: false, organizers: [] } })
  show(false)
  expect(await screen.findByLabelText('emailBase.signup')).toBeChecked()
  expect(screen.getByLabelText('Organizer')).not.toBeChecked()
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.unsubscribeAll' }))
  await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/email_preferences/token', { unsubscribe_all: true }))
  expect(screen.getByText('emailBase.transactional')).toBeInTheDocument()
})
