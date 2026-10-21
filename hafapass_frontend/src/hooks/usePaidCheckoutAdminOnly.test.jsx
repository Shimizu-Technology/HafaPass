import { renderHook, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import usePaidCheckoutAdminOnly from './usePaidCheckoutAdminOnly'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))

beforeEach(() => { vi.clearAllMocks() })

describe('usePaidCheckoutAdminOnly', () => {
  it('reads the server flag once a paid selection exists', async () => {
    apiClient.get.mockResolvedValue({ data: { paid_checkout_admin_only: true } })
    const { result, rerender } = renderHook(({ enabled }) => usePaidCheckoutAdminOnly(enabled), { initialProps: { enabled: false } })
    await Promise.resolve()
    expect(apiClient.get).not.toHaveBeenCalled()
    rerender({ enabled: true })
    await waitFor(() => expect(result.current).toBe(true))
    expect(apiClient.get).toHaveBeenCalledWith('/config')
  })
})
