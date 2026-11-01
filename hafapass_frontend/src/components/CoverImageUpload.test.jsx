import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import CoverImageUpload from './CoverImageUpload'
import { uploadImage } from '../utils/uploads'
import { downscaleImage, oversizedInput } from '../utils/imageDownscale'

vi.mock('../utils/uploads', () => ({ uploadImage: vi.fn() }))
vi.mock('../utils/imageDownscale', () => ({ downscaleImage: vi.fn(async file => file), oversizedInput: vi.fn(async () => null) }))

describe('cover image recovery', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    downscaleImage.mockImplementation(async file => file)
    oversizedInput.mockImplementation(async () => null)
    URL.createObjectURL = vi.fn(() => 'blob:preview')
    URL.revokeObjectURL = vi.fn()
  })

  it('shows the actionable failure and retries the same file without reopening the picker', async () => {
    uploadImage.mockRejectedValueOnce({ response: { data: { error: 'Verification was interrupted. Retry completion.' } } })
    uploadImage.mockResolvedValueOnce('https://images.invalid/verified.png')
    const onUploaded = vi.fn()
    const { container } = render(<CoverImageUpload eventId={37} onUploaded={onUploaded} />)
    const file = new File(['image bytes'], 'cover.png', { type: 'image/png' })
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [file] } })
    expect(await screen.findByRole('alert')).toHaveTextContent('Retry completion')
    fireEvent.click(screen.getByRole('button', { name: 'Retry image upload' }))
    await waitFor(() => expect(onUploaded).toHaveBeenCalledWith('https://images.invalid/verified.png'))
    expect(uploadImage.mock.calls.map(([selected]) => selected)).toEqual([file, file])
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('does not attach an old upload to a newly selected event', async () => {
    let finish
    uploadImage.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    const onUploaded = vi.fn()
    const { container, rerender } = render(<CoverImageUpload eventId={37} onUploaded={onUploaded} />)
    const file = new File(['image bytes'], 'cover.png', { type: 'image/png' })
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [file] } })
    // The image is prepared (resized when supported) before the upload starts.
    await waitFor(() => expect(uploadImage).toHaveBeenCalled())
    rerender(<CoverImageUpload eventId={38} onUploaded={onUploaded} />)
    finish('https://images.invalid/old-event.png')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Upload cover image' })).toBeInTheDocument())
    expect(onUploaded).not.toHaveBeenCalled()
  })

  it('ignores keyboard-generated clicks and clamps pointer focal points', () => {
    const onFocalChange = vi.fn()
    render(<CoverImageUpload eventId={37} currentUrl="https://storage.invalid/uploads/cover.webp"
      imageAssetHost="storage.invalid" focalPoint={{ x: 50, y: 50 }} onFocalChange={onFocalChange} />)
    const button = screen.getByRole('button', { name: 'Set cover focal point' })
    button.getBoundingClientRect = () => ({ left: 10, top: 20, width: 100, height: 100 })
    fireEvent.click(button, { detail: 0, clientX: 0, clientY: 0 })
    expect(onFocalChange).not.toHaveBeenCalled()
    fireEvent.click(button, { detail: 1, clientX: -50, clientY: 400 })
    expect(onFocalChange).toHaveBeenLastCalledWith({ x: 0, y: 100 })
    fireEvent.keyDown(button, { key: 'ArrowRight' })
    expect(onFocalChange).toHaveBeenLastCalledWith({ x: 55, y: 50 })
  })

  it('uploads the resized photo, accepts a large original it shrinks, and retries the same resized bytes', async () => {
    const original = new File(['x'.repeat(16)], 'IMG_0001.JPG', { type: 'image/jpeg' })
    Object.defineProperty(original, 'size', { value: 9 * 1024 * 1024 })
    const resized = new File(['small'], 'IMG_0001.webp', { type: 'image/webp' })
    downscaleImage.mockResolvedValue(resized)
    uploadImage.mockRejectedValueOnce(new Error('Network Error'))
    uploadImage.mockResolvedValueOnce('https://images.invalid/resized.webp')
    const onUploaded = vi.fn()
    const { container } = render(<CoverImageUpload eventId={37} onUploaded={onUploaded} />)
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [original] } })
    expect(await screen.findByRole('alert')).toHaveTextContent('interrupted')
    fireEvent.click(screen.getByRole('button', { name: 'Retry image upload' }))
    await waitFor(() => expect(onUploaded).toHaveBeenCalledWith('https://images.invalid/resized.webp'))
    expect(uploadImage.mock.calls.map(([selected]) => selected)).toEqual([resized, resized])
    // Recovery is keyed by the photo the organizer picked, not the resized copy.
    expect(uploadImage.mock.calls.map(([, , , options]) => options.source)).toEqual([original, original])
    expect(downscaleImage).toHaveBeenCalledTimes(1)
    expect(oversizedInput).toHaveBeenCalledTimes(1)
  })

  it('still rejects an image that stays over 5MB', async () => {
    const original = new File(['x'], 'huge.png', { type: 'image/png' })
    Object.defineProperty(original, 'size', { value: 6 * 1024 * 1024 })
    const { container } = render(<CoverImageUpload eventId={37} onUploaded={vi.fn()} />)
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [original] } })
    expect(await screen.findByRole('alert')).toHaveTextContent('Image must be under 5MB.')
    expect(uploadImage).not.toHaveBeenCalled()
  })

  it.each(['bytes', 'pixels'])('refuses an original too large to decode (%s) before previewing or resizing it', async reason => {
    oversizedInput.mockResolvedValueOnce(reason)
    const original = new File(['x'], 'IMG_9999.HEIC.jpg', { type: 'image/jpeg' })
    Object.defineProperty(original, 'size', { value: 40 * 1024 * 1024 })
    const { container } = render(<CoverImageUpload eventId={37} onUploaded={vi.fn()} />)
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [original] } })
    expect(await screen.findByRole('alert')).toHaveTextContent('too large to prepare here. Choose one under 25 MB and 50 megapixels')
    expect(URL.createObjectURL).not.toHaveBeenCalled()
    expect(downscaleImage).not.toHaveBeenCalled()
    expect(uploadImage).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Upload cover image' })).not.toHaveAttribute('tabindex', '-1')
  })

  it.each([
    ['a plain axios abort', { code: 'ECONNABORTED', message: 'Request aborted' }],
    ['a canceled request', { code: 'ERR_CANCELED', message: 'canceled' }],
    ['a timeout', { code: 'ECONNABORTED', isTimeout: true, message: 'Your connection is slow' }],
  ])('offers recovery after %s', async (_label, failure) => {
    uploadImage.mockRejectedValueOnce(Object.assign(new Error(failure.message), failure))
    const { container } = render(<CoverImageUpload eventId={37} onUploaded={vi.fn()} />)
    fireEvent.change(container.querySelector('input[type="file"]'), { target: { files: [new File(['x'], 'cover.jpg', { type: 'image/jpeg' })] } })
    expect(await screen.findByRole('alert')).toHaveTextContent('Image upload was interrupted. Retry the upload to recover it.')
    expect(screen.getByRole('button', { name: 'Retry image upload' })).toBeInTheDocument()
  })
})
