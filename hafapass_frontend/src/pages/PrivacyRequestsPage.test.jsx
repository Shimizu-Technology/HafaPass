import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { getOrderAccess } from '../utils/orderAccess'
import { GuestPrivacyRequestsPage } from './PrivacyRequestsPage'

vi.mock('../api/client', async importOriginal => ({ ...await importOriginal(), default: { post: vi.fn() } }))
vi.mock('../utils/orderAccess', async importOriginal => ({ ...await importOriginal(), getOrderAccess: vi.fn() }))

const show = () => render(<MemoryRouter initialEntries={['/privacy/guest/27']}>
  <Routes><Route path="/privacy/guest/:orderId" element={<GuestPrivacyRequestsPage />} /></Routes>
</MemoryRouter>)

describe('guest privacy requests', () => {
  beforeEach(() => { vi.clearAllMocks(); getOrderAccess.mockReturnValue('verified-link') })

  it('submits only with the verified order link', async () => {
    apiClient.post.mockResolvedValue({ data: { id: 3 } })
    show()
    await userEvent.click(screen.getByRole('button', { name: 'Request my data' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/guest_privacy_requests',
      { kind: 'access', order_id: '27', guest_token: 'verified-link' }))
    expect(screen.getByRole('status')).toHaveTextContent('Request submitted')
  })

  it('explains how to recover access when the link is missing', async () => {
    getOrderAccess.mockReturnValue(null)
    show()
    expect(screen.getByRole('alert')).toHaveTextContent('Open the secure link')
    await userEvent.click(screen.getByRole('button', { name: 'Request deletion' }))
    expect(apiClient.post).not.toHaveBeenCalled()
  })
})
