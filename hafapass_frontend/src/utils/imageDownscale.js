// Cover photos straight from a phone are often 4000+ px and several MB, but
// pages show them at most ~1600 px wide. Shrinking in the browser keeps uploads
// fast on mobile data. Re-encoding through a canvas also drops camera metadata
// such as location; an image already small enough to skip resizing uploads
// unchanged, metadata included. The server still validates type, size and
// signature exactly as before.
export const COVER_MAX_EDGE = 1600
export const COVER_QUALITY = 0.82
// PNG flyers are often text and line art, which lossy WebP at photo quality
// smears. They stay PNG when that fits, otherwise get a higher WebP quality.
export const PNG_WEBP_QUALITY = 0.92
export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024
// Decoding very large originals can exhaust memory on phones (Safari reloads
// the tab and the unsaved event form is lost), so they are refused up front.
export const MAX_INPUT_BYTES = 25 * 1024 * 1024
export const MAX_INPUT_PIXELS = 50_000_000

const HEADER_BYTES = 256 * 1024

async function readBytes(blob) {
  if (blob.arrayBuffer) return new Uint8Array(await blob.arrayBuffer())
  return new Uint8Array(await new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error)
    reader.readAsArrayBuffer(blob)
  }))
}

// Width and height from the file header (PNG, JPEG, WebP) without decoding
// pixels, or null when the header is not recognized.
export function headerDimensions(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const ascii = (offset, length) => String.fromCharCode(...bytes.subarray(offset, offset + length))
  if (bytes.length >= 24 && bytes[0] === 0x89 && ascii(1, 3) === 'PNG' && ascii(12, 4) === 'IHDR') {
    return { width: view.getUint32(16), height: view.getUint32(20) }
  }
  if (bytes.length >= 32 && ascii(0, 4) === 'RIFF' && ascii(8, 4) === 'WEBP') {
    const chunk = ascii(12, 4)
    if (chunk === 'VP8X') return { width: 1 + (view.getUint32(24, true) & 0xffffff), height: 1 + (view.getUint32(27, true) & 0xffffff) }
    if (chunk === 'VP8L') {
      const bits = view.getUint32(21, true)
      return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >> 14) & 0x3fff) }
    }
    if (chunk === 'VP8 ') return { width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff }
    return null
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) return null
      const marker = bytes[offset + 1]
      if (marker === 0xff) { offset += 1; continue }
      // Standalone markers (TEM, RSTn, SOI) have no length field.
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) { offset += 2; continue }
      // SOF0-SOF15 carry the frame size; DHT (C4), JPG (C8) and DAC (CC) do not.
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        return { width: view.getUint16(offset + 7), height: view.getUint16(offset + 5) }
      }
      offset += 2 + view.getUint16(offset + 2)
    }
  }
  return null
}

// Why an original is too large to prepare in the browser: 'bytes', 'pixels',
// or null when it is safe to decode.
export async function oversizedInput(file) {
  if (file.size > MAX_INPUT_BYTES) return 'bytes'
  try {
    const size = headerDimensions(await readBytes(file.slice(0, HEADER_BYTES)))
    if (size && size.width * size.height > MAX_INPUT_PIXELS) return 'pixels'
  } catch {
    // An unreadable header is left to the decoder and the server.
  }
  return null
}

function makeCanvas(width, height) {
  if (typeof OffscreenCanvas === 'function') return new OffscreenCanvas(width, height)
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  return canvas
}

function encode(canvas, type, quality) {
  if (typeof canvas.convertToBlob === 'function') return canvas.convertToBlob({ type, quality })
  return new Promise(resolve => canvas.toBlob(resolve, type, quality))
}

// Returns a smaller WebP (or, where the browser cannot encode WebP, a JPEG for
// JPEG sources; a PNG for PNG sources when that fits the upload limit).
// Returns the original file when it already fits the page and the upload
// limit, and whenever resizing is unsupported, fails, or would not make the
// file smaller.
export async function downscaleImage(file, { maxEdge = COVER_MAX_EDGE, quality = COVER_QUALITY } = {}) {
  if (typeof createImageBitmap !== 'function') return file
  let bitmap
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
  } catch {
    return file
  }
  try {
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
    // Nothing to gain from a lossy re-encode of an image that already fits.
    if (scale === 1 && file.size <= MAX_UPLOAD_BYTES) return file
    const width = Math.max(1, Math.round(bitmap.width * scale))
    const height = Math.max(1, Math.round(bitmap.height * scale))
    const canvas = makeCanvas(width, height)
    const context = canvas.getContext('2d')
    if (!context) return file
    context.imageSmoothingQuality = 'high'
    context.drawImage(bitmap, 0, 0, width, height)
    let type = 'image/webp'
    let blob
    if (file.type === 'image/png') {
      const png = await encode(canvas, 'image/png')
      if (png?.type === 'image/png' && png.size && png.size <= MAX_UPLOAD_BYTES) {
        type = 'image/png'
        blob = png
      }
    }
    if (!blob) blob = await encode(canvas, type, file.type === 'image/png' ? PNG_WEBP_QUALITY : quality)
    // Safari answers a WebP request with PNG. JPEG keeps photos small there;
    // PNG and WebP sources may be transparent, so they keep the original.
    if (blob?.type !== type) {
      if (file.type !== 'image/jpeg') return file
      type = 'image/jpeg'
      blob = await encode(canvas, type, quality)
      if (blob?.type !== type) return file
    }
    if (!blob.size || blob.size >= file.size) return file
    const extension = { 'image/webp': 'webp', 'image/jpeg': 'jpg', 'image/png': 'png' }[type]
    const name = `${file.name.replace(/\.[^.]*$/, '') || 'cover'}.${extension}`
    return new File([blob], name, { type, lastModified: file.lastModified })
  } catch {
    return file
  } finally {
    bitmap.close?.()
  }
}
