import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import apiClient from '../api/client'
import EnvironmentBanner from './EnvironmentBanner'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

describe('test environment identification', () => {
  beforeEach(() => { vi.clearAllMocks(); window.localStorage.clear() })
  it('labels the actual non-production environment even when payment configuration differs', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'test', payment_mode: 'stripe' } })
    render(<EnvironmentBanner />)
    expect(await screen.findByRole('status')).toHaveTextContent('Test environment')
  })
  it('does not label a production free event as a test environment', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'production', payment_mode: 'simulate' } })
    const view = render(<EnvironmentBanner />)
    await vi.waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    expect(view.container).toBeEmptyDOMElement()
  })
  it('warns about test payments on production while Stripe is in test mode', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'production', payment_mode: 'test' } })
    render(<EnvironmentBanner />)
    expect(await screen.findByRole('status')).toHaveTextContent('Test payments. Only Stripe test cards work; no real card is charged. Tickets bought now are for testing.')
    expect(window.localStorage.getItem('hafapass_runtime_payment_mode')).toBe('test')
  })
  it('never shows a test banner once payments are live', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'production', payment_mode: 'live' } })
    const view = render(<EnvironmentBanner />)
    await vi.waitFor(() => expect(window.localStorage.getItem('hafapass_runtime_payment_mode')).toBe('live'))
    expect(view.container).toBeEmptyDOMElement()
  })
  it('uses the remembered mode when offline', () => {
    window.localStorage.setItem('hafapass_runtime_environment', 'production')
    window.localStorage.setItem('hafapass_runtime_payment_mode', 'test')
    render(<EnvironmentBanner offlineOnly />)
    expect(screen.getByRole('status')).toHaveTextContent('Test payments')
    expect(apiClient.get).not.toHaveBeenCalled()
  })
})
