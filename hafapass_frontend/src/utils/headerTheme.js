// Shared by Navbar and the generated pre-React startup script.
export function isDarkHeaderPath(pathname, scrolled = false) {
  return pathname.startsWith('/tickets/') || (!scrolled && (
    ['/', '/host', '/events', '/discover', '/my-tickets', '/saved'].includes(pathname)
    || pathname.startsWith('/collections/')
  ))
}
