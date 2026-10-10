import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import CreateEventPage from './CreateEventPage'
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [] }))
function mount() { return render(<MemoryRouter><CreateEventPage /></MemoryRouter>) }
beforeEach(() => vi.clearAllMocks())
it('denies direct creation to staff with a dashboard recovery link and no form', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: false } } })
  mount()
  await screen.findByText(/does not include creating events/)
  expect(screen.getByRole('link', { name: 'Back to dashboard' })).toHaveAttribute('href', '/dashboard')
  expect(screen.queryByLabelText(/Event Title/)).not.toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
})
it('preserves permitted creation and fails closed when confirmation is unavailable', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: true } } })
  const view = mount()
  await screen.findByRole('heading', { name: 'Create New Event' })
  view.unmount()
  apiClient.get.mockRejectedValue(new Error('Unavailable'))
  mount()
  await screen.findByText(/Could not confirm event creation access/)
  expect(screen.queryByLabelText(/Event Title/)).not.toBeInTheDocument()
})
