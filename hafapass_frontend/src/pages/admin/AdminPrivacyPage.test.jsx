import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminPrivacyPage from './AdminPrivacyPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../hooks/usePlatformContext', () => {
  const beginRequest = () => ({ config: {}, current: () => true,
    handleError: () => false, release: () => {} })
  return { usePlatformRequests: () => ({ beginRequest }) }
})
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('./AdminSessionGate', () => ({ default: ({ Session, resourcePath }) => <Session identity={{}} resourcePath={resourcePath} /> }))

const request = { id: 7, kind: 'access', status: 'verified', user_id: 2, verified_at: 'now', result: {} }
const detail = { request, preview: { blockers: [], dry_run: true, retained: [], deleted: [] } }

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/legal_holds') ? { holds: [] }
    : path.endsWith('/privacy_requests') ? { requests: [request] } : detail }))
  apiClient.post.mockResolvedValue({ data: { request } })
})

describe('admin privacy execution', () => {
  it('requires explicit confirmation to execute during dry-run', async () => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    render(<AdminPrivacyPage />)
    await user.click(await screen.findByRole('button', { name: /access #7/ }))
    await user.click(await screen.findByRole('button', { name: 'Execute request' }))
    expect(apiClient.post).not.toHaveBeenCalled()

    window.confirm.mockReturnValue(true)
    await user.click(screen.getByRole('button', { name: 'Execute request' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/privacy_requests/7/execute',
      { confirm_dry_run: true }, expect.anything()))
    window.confirm.mockRestore()
  })

  it('does not offer admin verification for a guest without the email challenge', async () => {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/legal_holds') ? { holds: [] }
      : path.endsWith('/privacy_requests') ? { requests: [{ ...request, user_id: null, verified_at: null }] }
        : { ...detail, request: { ...request, user_id: null, verified_at: null } } }))
    render(<AdminPrivacyPage />)
    await userEvent.click(await screen.findByRole('button', { name: /access #7/ }))
    expect(await screen.findByText(/guest must enter the code/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Verify identity' })).not.toBeInTheDocument()
  })
})
