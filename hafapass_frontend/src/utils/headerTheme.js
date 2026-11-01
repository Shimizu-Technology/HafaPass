// Shared by Navbar and the generated pre-React startup script.
export function isDarkHeaderPath(pathname, scrolled = false) {
  return pathname.startsWith('/tickets/') || /^\/sign-(?:in|up)(?:\/|$)/.test(pathname) || (!scrolled && (
    ['/', '/host', '/events', '/discover', '/my-tickets', '/saved'].includes(pathname)
    || pathname.startsWith('/collections/')
  ))
}

// Routes whose whole first screen is dark (the Home hero, the Host pricing
// band, a ticket). The pre-React splash paints these dark so the page does not
// flash light first. Title-band routes keep a light page: only the header
// and band are dark there. Also inlined by the startup script.
export function isDarkPagePath(pathname) {
  return pathname === '/' || pathname === '/host' || pathname.startsWith('/tickets/')
}
