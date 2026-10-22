import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import CoverImageUpload from './CoverImageUpload'
import { uploadImage } from '../utils/uploads'

vi.mock('../utils/uploads', () => ({ uploadImage: vi.fn() }))

describe('cover image recovery', () => {
  beforeEach(() => {
    vi.clearAllMocks()
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
})
