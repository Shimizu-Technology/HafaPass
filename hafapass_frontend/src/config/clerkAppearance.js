// Clerk renders its own sign-in/up cards; these values mirror the HafaPass tokens in
// tailwind.config.js so the auth screens use the same primary action (red), text,
// radius and font as the rest of the site.
export const clerkAppearance = {
  variables: {
    colorPrimary: '#c9362e', // action
    colorDanger: '#b91c1c', // action-danger
    colorForeground: '#0f172a', // content
    colorMutedForeground: '#475569', // content-muted
    colorInputForeground: '#0f172a',
    colorInput: '#ffffff',
    colorBackground: '#ffffff',
    fontFamily: '"Plus Jakarta Sans Variable", system-ui, -apple-system, sans-serif',
    borderRadius: '0.75rem',
  },
  elements: {
    card: 'shadow-card border border-neutral-200/60',
    formButtonPrimary: 'min-h-11 font-semibold normal-case shadow-none transition-[background-color,transform] duration-150 ease-out-strong hover:bg-action-hover active:scale-[0.97]',
    footerActionLink: 'font-semibold text-brand-800 hover:text-brand-900',
    formFieldInput: 'min-h-11',
  },
}
