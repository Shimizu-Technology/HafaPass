import { afterEach, describe, expect, it, vi } from 'vitest'
import { downscaleImage } from './imageDownscale'

function installCanvas({ bitmap = { width: 4032, height: 3024 }, encodes = { 'image/webp': 'image/webp', 'image/jpeg': 'image/jpeg' }, size = 300_000 } = {}) {
  const drawn = []
  const encoded = []
  const close = vi.fn()
  globalThis.createImageBitmap = vi.fn(async () => ({ ...bitmap, close }))
  globalThis.OffscreenCanvas = class {
    constructor(width, height) { this.width = width; this.height = height }
    getContext() { return { drawImage: (_image, x, y, width, height) => drawn.push({ width, height }) } }
    async convertToBlob({ type, quality }) {
      encoded.push({ type, quality })
      return new Blob([new Uint8Array(size)], { type: encodes[type] || 'image/png' })
    }
  }
  return { drawn, encoded, close }
}

const photo = (type = 'image/jpeg', bytes = 4_000_000, name = 'IMG_0001.JPG') => {
  const file = new File(['x'], name, { type })
  Object.defineProperty(file, 'size', { value: bytes })
  return file
}

describe('downscaleImage', () => {
  afterEach(() => { delete globalThis.createImageBitmap; delete globalThis.OffscreenCanvas })

  it('keeps the original where the browser cannot decode images off-screen', async () => {
    const file = photo()
    expect(await downscaleImage(file)).toBe(file)
  })

  it('resizes to 1600 px on the longest side as WebP at 0.82, honoring photo orientation', async () => {
    const { drawn, encoded, close } = installCanvas()
    const result = await downscaleImage(photo())
    expect(createImageBitmap).toHaveBeenCalledWith(expect.any(File), { imageOrientation: 'from-image' })
    expect(drawn).toEqual([{ width: 1600, height: 1200 }])
    expect(encoded).toEqual([{ type: 'image/webp', quality: 0.82 }])
    expect(result).toMatchObject({ name: 'IMG_0001.webp', type: 'image/webp', size: 300_000 })
    expect(close).toHaveBeenCalled()
  })

  it('never enlarges a small image', async () => {
    const { drawn } = installCanvas({ bitmap: { width: 900, height: 1200 } })
    await downscaleImage(photo())
    expect(drawn).toEqual([{ width: 900, height: 1200 }])
  })

  it('falls back to JPEG for JPEG photos when the browser cannot encode WebP', async () => {
    const { encoded } = installCanvas({ encodes: { 'image/jpeg': 'image/jpeg' } })
    const result = await downscaleImage(photo())
    expect(encoded.map(item => item.type)).toEqual(['image/webp', 'image/jpeg'])
    expect(result).toMatchObject({ name: 'IMG_0001.jpg', type: 'image/jpeg' })
  })

  it('keeps a PNG original when WebP is unavailable, since it may be transparent', async () => {
    installCanvas({ encodes: {} })
    const file = photo('image/png', 4_000_000, 'logo.png')
    expect(await downscaleImage(file)).toBe(file)
  })

  it('keeps the original when the resized file would not be smaller or decoding fails', async () => {
    installCanvas({ size: 500_000 })
    const small = photo('image/jpeg', 400_000)
    expect(await downscaleImage(small)).toBe(small)
    globalThis.createImageBitmap = vi.fn(async () => { throw new Error('decode failed') })
    const broken = photo()
    expect(await downscaleImage(broken)).toBe(broken)
  })
})
