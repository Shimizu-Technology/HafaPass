import { afterEach, expect, it, vi } from 'vitest'
import { saveBlob } from './download'

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

it('clicks an attached link and keeps the blob URL alive until the download has started', () => {
  vi.useFakeTimers()
  const create = vi.spyOn(window.URL, 'createObjectURL').mockReturnValue('blob:export')
  const revoke = vi.spyOn(window.URL, 'revokeObjectURL').mockImplementation(() => {})
  const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function () {
    expect(this.isConnected).toBe(true)
  })
  saveBlob(new Blob(['a,b']), 'sales.csv')
  expect(create).toHaveBeenCalled()
  expect(click).toHaveBeenCalledTimes(1)
  expect(click.mock.instances[0]).toHaveAttribute('download', 'sales.csv')
  expect(document.querySelector('a[download]')).toBeNull()
  expect(revoke).not.toHaveBeenCalled()
  vi.advanceTimersByTime(30_000)
  expect(revoke).toHaveBeenCalledWith('blob:export')
})
