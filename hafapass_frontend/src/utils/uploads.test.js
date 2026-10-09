import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { webcrypto } from 'node:crypto'
import apiClient from '../api/client'
import { uploadImage } from './uploads'

vi.mock('../api/client', () => ({ default: { post: vi.fn() } }))

describe('verified uploads', () => {
  const file = new File(['image bytes'], 'cover.png', { type: 'image/png' })
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.post.mockReset()
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.localStorage.setItem('hafapass_scanner_user_id', 'original-user')
    vi.stubGlobal('crypto', webcrypto)
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

  it('recovers a lost completion response after module reload without another storage upload', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    await expect(uploadImage(file, 37)).rejects.toThrow('Response lost')
    vi.resetModules()
    const reloaded = await import('./uploads')
    apiClient.post.mockResolvedValueOnce({ data: { public_url: 'https://images.invalid/original.png' } })
    expect(await reloaded.uploadImage(file, 37)).toBe('https://images.invalid/original.png')
    expect(apiClient.post.mock.calls.map(([path]) => path)).toEqual(['/uploads/presign', '/uploads/complete', '/uploads/complete'])
    expect(apiClient.post.mock.calls[2][1]).toEqual({ upload_token: 'scoped-token' })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(window.sessionStorage.length).toBe(0)
  })

  it('does not reuse another account’s pending completion', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    await expect(uploadImage(file, 37)).rejects.toThrow()
    window.localStorage.setItem('hafapass_scanner_user_id', 'other-user')
    apiClient.post.mockResolvedValueOnce({ data: { url: 'https://storage.invalid/new', fields: {}, upload_token: 'other-token' } })
    apiClient.post.mockResolvedValueOnce({ data: { public_url: 'https://images.invalid/other.png' } })
    await uploadImage(file, 37)
    expect(apiClient.post.mock.calls[2][0]).toBe('/uploads/presign')
    expect(apiClient.post.mock.calls[3][1]).toEqual({ upload_token: 'other-token' })
  })

  it('does not reuse another organization’s pending logo completion', async () => {
    window.localStorage.setItem('hafapass_organization_id', 'org-a')
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    await expect(uploadImage(file)).rejects.toThrow()
    window.localStorage.setItem('hafapass_organization_id', 'org-b')
    apiClient.post.mockResolvedValueOnce({ data: { url: 'https://storage.invalid/org-b', fields: {}, upload_token: 'org-b-token' } })
    apiClient.post.mockResolvedValueOnce({ data: { public_url: 'https://images.invalid/org-b.png' } })
    await uploadImage(file)
    expect(apiClient.post.mock.calls[2][0]).toBe('/uploads/presign')
    expect(apiClient.post.mock.calls[3][1]).toEqual({ upload_token: 'org-b-token' })
  })

  it('rejects a completion result after organization changes and preserves a replacement token', async () => {
    let finish
    apiClient.post.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    const pending = uploadImage(file, 37)
    await vi.waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    const key = window.sessionStorage.key(0)
    window.sessionStorage.setItem(key, 'replacement-token')
    window.localStorage.setItem('hafapass_organization_id', 'new-org')
    finish({ data: { public_url: 'https://images.invalid/old.png' } })
    await expect(pending).rejects.toThrow('organization changed')
    expect(window.sessionStorage.getItem(key)).toBe('replacement-token')
  })

  it('requires a fresh authorization after a definitively rejected completion', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 403 } })
    await expect(uploadImage(file, 37)).rejects.toEqual({ response: { status: 403 } })
    expect(window.sessionStorage.length).toBe(0)
    apiClient.post.mockResolvedValueOnce({ data: { url: 'https://storage.invalid/new', fields: {}, upload_token: 'fresh-token' } })
    apiClient.post.mockResolvedValueOnce({ data: { public_url: 'https://images.invalid/fresh.png' } })
    await uploadImage(file, 37)
    expect(apiClient.post.mock.calls[2][0]).toBe('/uploads/presign')
    expect(apiClient.post.mock.calls[3][1]).toEqual({ upload_token: 'fresh-token' })
  })

  it('rejects oversized files before reading them or starting an upload', async () => {
    const oversized = { size: 6 * 1024 * 1024, type: 'image/png', arrayBuffer: vi.fn() }
    await expect(uploadImage(oversized, 37)).rejects.toThrow('5 MB')
    expect(oversized.arrayBuffer).not.toHaveBeenCalled()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
})
