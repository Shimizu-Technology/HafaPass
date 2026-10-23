import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import ActivityExportButton from './ActivityExportButton'

const api = { createExport: vi.fn(), exportStatus: vi.fn(), downloadExport: vi.fn() }
let request
let click
beforeEach(() => {
  vi.clearAllMocks()
  request = { config: { signal: new AbortController().signal, organizationId: '7' }, current: vi.fn(() => true), release: vi.fn(), handleError: vi.fn(() => false) }
  click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn(() => 'blob:csv'), revokeObjectURL: vi.fn() }))
  api.createExport.mockResolvedValue({ data: { export: { id: 9, status: 'ready', download_url: '/api/v1/organizer/activity_log_exports/9/download' } } })
  api.downloadExport.mockResolvedValue({ data: 'When,Activity\nToday,Updated event' })
})
afterEach(() => { click.mockRestore(); vi.unstubAllGlobals() })
const mount = () => render(<ActivityExportButton api={api} params={{ event_id: '4', outcome: 'failed' }} beginRequest={() => request} />)

it('exports the exact active filters and downloads through the authenticated API', async () => {
  const user = userEvent.setup()
  mount()
  await user.click(screen.getByRole('button', { name: 'Download CSV' }))
  expect(await screen.findByText('CSV downloaded.')).toBeInTheDocument()
  expect(api.createExport).toHaveBeenCalledWith({ event_id: '4', outcome: 'failed' }, request.config)
  expect(api.downloadExport).toHaveBeenCalledWith(9, request.config)
  expect(click).toHaveBeenCalledOnce()
  expect(request.release).toHaveBeenCalledOnce()
})

it('checks a pending export, then lets a failed export be retried', async () => {
  const user = userEvent.setup()
  api.createExport.mockResolvedValueOnce({ data: { export: { id: 9, status: 'pending' } } })
  api.exportStatus.mockResolvedValueOnce({ data: { export: { id: 9, status: 'failed' } } })
  mount()
  await user.click(screen.getByRole('button', { name: 'Download CSV' }))
  await user.click(await screen.findByRole('button', { name: 'Check CSV status' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('CSV could not be downloaded')
  expect(api.exportStatus).toHaveBeenCalledWith(9, request.config)
  await user.click(screen.getByRole('button', { name: 'Retry CSV export' }))
  expect(await screen.findByText('CSV downloaded.')).toBeInTheDocument()
  expect(api.createExport).toHaveBeenCalledTimes(2)
})

it('never downloads an export after account or organization authority changes', async () => {
  const user = userEvent.setup()
  let resolve
  api.createExport.mockImplementation(() => new Promise(done => { resolve = done }))
  mount()
  await user.click(screen.getByRole('button', { name: 'Download CSV' }))
  request.current.mockReturnValue(false)
  await act(async () => resolve({ data: { export: { id: 9, status: 'ready' } } }))
  expect(api.downloadExport).not.toHaveBeenCalled()
  expect(click).not.toHaveBeenCalled()
})

it('ignores a late CSV response after the filter-bound control unmounts', async () => {
  const user = userEvent.setup()
  let resolve
  api.downloadExport.mockImplementation(() => new Promise(done => { resolve = done }))
  const view = mount()
  await user.click(screen.getByRole('button', { name: 'Download CSV' }))
  view.unmount()
  await act(async () => resolve({ data: 'private csv' }))
  expect(click).not.toHaveBeenCalled()
  expect(request.release).toHaveBeenCalled()
})
