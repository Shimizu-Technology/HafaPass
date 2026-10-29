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
    rootBox: 'w-full max-w-md',
    headerTitle: 'font-display font-bold',
    cardBox: 'w-full max-w-full',
    card: 'w-full max-w-full shadow-card border border-neutral-200/60',
    formButtonPrimary: 'min-h-11 font-semibold normal-case shadow-none transition-[background-color,transform] duration-150 ease-out-strong hover:bg-action-hover active:scale-[0.97]',
    socialButtonsBlockButton: 'min-h-11',
    formFieldInputShowPasswordButton: 'min-h-11 min-w-11 inline-flex items-center justify-center',
    footerAction: 'flex flex-wrap items-center justify-center gap-x-1',
    footerActionLink: 'inline-block min-h-11 min-w-11 py-3 -my-3 whitespace-nowrap align-middle font-semibold text-brand-800 hover:text-brand-900',
    formFieldInput: 'min-h-11',
  },
}

// Clerk React 5.61.9 / @clerk/shared LocalizationResource: start title and
// subtitle have separate combined-flow keys. Partial resources retain all
// other Clerk wording and the free-plan branding.
export const clerkLocalization = {
  signIn: {
    start: {
      title: 'Sign in to HåfaPass',
      titleCombined: 'Sign in to HåfaPass',
      subtitle: 'Use the account you bought tickets or host events with.',
      subtitleCombined: 'Use the account you bought tickets or host events with.',
    },
  },
  signUp: {
    start: {
      title: 'Create your HåfaPass account',
      titleCombined: 'Create your HåfaPass account',
      subtitle: "Save your tickets and events in one place. You don't need an account to buy tickets.",
      subtitleCombined: "Save your tickets and events in one place. You don't need an account to buy tickets.",
    },
  },
}
