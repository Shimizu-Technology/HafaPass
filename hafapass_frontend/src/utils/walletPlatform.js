// Which wallet buttons a buyer's device can use. Apple platforms (including
// iPadOS, which reports itself as a Mac) get Apple Wallet; Android and other
// identified platforms get Google Wallet. An unrecognized browser keeps both.
export function walletPlatform(nav = typeof navigator === 'undefined' ? undefined : navigator) {
  const userAgent = nav?.userAgent || ''
  const platform = nav?.userAgentData?.platform || ''
  // The user-agent string decides first: it stays accurate when a browser or
  // test harness overrides it. Client hints only fill in an inconclusive one.
  if (/Android/.test(userAgent)) return 'android'
  if (/iPhone|iPad|iPod|Macintosh/.test(userAgent)) return 'apple'
  if (/Windows NT|CrOS|X11/.test(userAgent)) return 'other'
  if (/Android/i.test(platform)) return 'android'
  if (/^(iOS|macOS)$/i.test(platform)) return 'apple'
  return platform ? 'other' : 'unknown'
}

export function visibleWallets(availability, platform = walletPlatform()) {
  return {
    apple: Boolean(availability?.apple) && ['apple', 'unknown'].includes(platform),
    google: Boolean(availability?.google) && platform !== 'apple',
  }
}
