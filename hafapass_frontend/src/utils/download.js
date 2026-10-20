// Saves a downloaded Blob (an API CSV export) under the given file name.
export function saveBlob(blob, filename) {
  const url = window.URL.createObjectURL(blob)
  try {
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.click()
  } finally {
    window.URL.revokeObjectURL(url)
  }
}
