// Preview-only demo-data mode gate.
// Keep this module free of fixture imports so production builds (where
// VITE_HAFAPASS_DEMO_DATA is unset) tree-shake all demo data out of dist/.
export function isDemoDataEnabled() {
  return import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1'
}

export function clerkPublishableKey() {
  return import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1'
    ? ''
    : (import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || '')
}

export function isClerkEnabled() {
  return Boolean(clerkPublishableKey())
}
