import { afterEach, describe, expect, it, vi } from 'vitest'
import { downscaleImage, headerDimensions, oversizedInput } from './imageDownscale'

function installCanvas({ bitmap = { width: 4032, height: 3024 }, encodes = { 'image/webp': 'image/webp', 'image/jpeg': 'image/jpeg', 'image/png': 'image/png' }, size = 300_000 } = {}) {
  const drawn = []
  const encoded = []
  const close = vi.fn()
  globalThis.createImageBitmap = vi.fn(async () => ({ ...bitmap, close }))
  globalThis.OffscreenCanvas = class {
    constructor(width, height) { this.width = width; this.height = height }
    getContext() { return { drawImage: (_image, x, y, width, height) => drawn.push({ width, height }) } }
    async convertToBlob({ type, quality }) {
      encoded.push({ type, quality })
      const bytes = typeof size === 'object' ? size[type] ?? size.default : size
      return new Blob([new Uint8Array(bytes)], { type: encodes[type] || 'image/png' })
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

  it('uploads an image that already fits unchanged instead of re-encoding it', async () => {
    const { drawn, encoded } = installCanvas({ bitmap: { width: 900, height: 1200 } })
    const flyer = photo('image/png', 2_000_000, 'flyer.png')
    expect(await downscaleImage(flyer)).toBe(flyer)
    expect(drawn).toEqual([])
    expect(encoded).toEqual([])
  })

  it('never enlarges a small image that must still shrink below 5 MB', async () => {
    const { drawn } = installCanvas({ bitmap: { width: 900, height: 1200 } })
    await downscaleImage(photo('image/jpeg', 6 * 1024 * 1024))
    expect(drawn).toEqual([{ width: 900, height: 1200 }])
  })

  it('keeps a resized PNG lossless when it fits under 5 MB', async () => {
    const { encoded } = installCanvas({ size: { 'image/png': 2_000_000, default: 300_000 } })
    const result = await downscaleImage(photo('image/png', 8_000_000, 'flyer.png'))
    expect(encoded.map(item => item.type)).toEqual(['image/png'])
    expect(result).toMatchObject({ name: 'flyer.png', type: 'image/png', size: 2_000_000 })
  })

  it('encodes a resized PNG that stays over 5 MB as high-quality WebP', async () => {
    const { encoded } = installCanvas({ size: { 'image/png': 6 * 1024 * 1024, default: 900_000 } })
    const result = await downscaleImage(photo('image/png', 12_000_000, 'flyer.png'))
    expect(encoded).toEqual([{ type: 'image/png', quality: undefined }, { type: 'image/webp', quality: 0.92 }])
    expect(result).toMatchObject({ name: 'flyer.webp', type: 'image/webp', size: 900_000 })
  })

  it('falls back to JPEG for JPEG photos when the browser cannot encode WebP', async () => {
    const { encoded } = installCanvas({ encodes: { 'image/jpeg': 'image/jpeg' } })
    const result = await downscaleImage(photo())
    expect(encoded.map(item => item.type)).toEqual(['image/webp', 'image/jpeg'])
    expect(result).toMatchObject({ name: 'IMG_0001.jpg', type: 'image/jpeg' })
  })

  it('keeps a PNG original when WebP is unavailable, since it may be transparent', async () => {
    installCanvas({ encodes: {}, size: { 'image/png': 6 * 1024 * 1024, default: 300_000 } })
    const file = photo('image/png', 8_000_000, 'logo.png')
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

describe('oversized originals', () => {
  const png = (width, height) => {
    const bytes = new Uint8Array(32)
    bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
    new DataView(bytes.buffer).setUint32(16, width)
    new DataView(bytes.buffer).setUint32(20, height)
    return bytes
  }
  const jpeg = (width, height) => {
    // SOI, an APP1 segment, a standalone RST marker, then SOF2 (progressive).
    const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe1, 0x00, 0x06, 1, 2, 3, 4, 0xff, 0xd0,
      0xff, 0xc2, 0x00, 0x11, 0x08, 0, 0, 0, 0, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    new DataView(bytes.buffer).setUint16(17, height)
    new DataView(bytes.buffer).setUint16(19, width)
    return bytes
  }
  const webp = (chunk, fill) => {
    const bytes = new Uint8Array(40)
    bytes.set([...'RIFF'].map(c => c.charCodeAt(0)), 0)
    bytes.set([...'WEBP'].map(c => c.charCodeAt(0)), 8)
    bytes.set([...chunk].map(c => c.charCodeAt(0)), 12)
    fill(new DataView(bytes.buffer))
    return bytes
  }

  it('reads PNG, JPEG and WebP dimensions from the header', () => {
    expect(headerDimensions(png(8000, 7000))).toEqual({ width: 8000, height: 7000 })
    expect(headerDimensions(jpeg(8064, 6048))).toEqual({ width: 8064, height: 6048 })
    expect(headerDimensions(webp('VP8X', view => { view.setUint32(24, 9999, true); view.setUint32(27, 4999, true) }))).toEqual({ width: 10000, height: 5000 })
    expect(headerDimensions(webp('VP8L', view => view.setUint32(21, 1599 | (899 << 14), true)))).toEqual({ width: 1600, height: 900 })
    expect(headerDimensions(webp('VP8 ', view => { view.setUint16(26, 4000, true); view.setUint16(28, 3000, true) }))).toEqual({ width: 4000, height: 3000 })
    expect(headerDimensions(new Uint8Array([1, 2, 3, 4]))).toBeNull()
  })

  it('refuses originals over 25 MB or 50 megapixels and allows ordinary phone photos', async () => {
    const big = new File(['x'], 'big.jpg', { type: 'image/jpeg' })
    Object.defineProperty(big, 'size', { value: 26 * 1024 * 1024 })
    expect(await oversizedInput(big)).toBe('bytes')
    expect(await oversizedInput(new File([png(10000, 6000)], 'poster.png', { type: 'image/png' }))).toBe('pixels')
    expect(await oversizedInput(new File([jpeg(8064, 6048)], 'IMG_48MP.jpg', { type: 'image/jpeg' }))).toBeNull()
    expect(await oversizedInput(new File(['not an image'], 'odd.webp', { type: 'image/webp' }))).toBeNull()
  })
})
