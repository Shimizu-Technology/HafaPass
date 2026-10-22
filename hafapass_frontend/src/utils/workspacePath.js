// Organizer, admin and support routes share the workspace shell instead of the
// public buyer navigation and marketing footer. Kept dependency-free so
// low-level helpers (locale, formatting) can use it.
export const isWorkspacePath = pathname => /^\/(dashboard|admin|support)(?:\/|$)/.test(pathname)
