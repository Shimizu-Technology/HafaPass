import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { uploadImage } from './uploads'

vi.mock('../api/client', () => ({ default: { post: vi.fn() } }))

describe('verified uploads', () => {
  const file = new File(['image bytes'], 'cover.png', { type: 'image/png' })
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.post.mockResolvedValueOnce({ data: { url: 'https://storage.invalid/cover', fields: { key: 'owned-key' }, upload_token: 'scoped-token' } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true }))
  })
  afterEach(() => vi.unstubAllGlobals())

  it('sends ownership and size, then uses only the completed server URL', async () => {
    apiClient.post.mockResolvedValueOnce({ data: { public_url: 'https://images.invalid/verified.png' } })
    expect(await uploadImage(file, 37)).toBe('https://images.invalid/verified.png')
    expect(apiClient.post.mock.calls[0]).toEqual(['/uploads/presign', { filename: file.name, content_type: file.type, byte_size: file.size, event_id: 37 }])
    expect(apiClient.post.mock.calls[1]).toEqual(['/uploads/complete', { upload_token: 'scoped-token' }])
  })

  it('does not confirm a storage upload rejected with an HTTP error', async () => {
    fetch.mockResolvedValue({ ok: false, status: 403 })
    await expect(uploadImage(file, 37)).rejects.toThrow('could not accept')
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })
})
