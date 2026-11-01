// Which wallet buttons a buyer's device can use. iPhone and iPad get Apple
// Wallet; Android gets Google Wallet. Desktop computers (Mac, Windows, Linux,
// ChromeOS) keep both, because buyers there often save a pass for a phone.
// iPadOS reports a Mac user agent; only its touch screen tells it apart.
export function walletPlatform(nav = typeof navigator === 'undefined' ? undefined : navigator) {
  const userAgent = nav?.userAgent || ''
  const platform = nav?.userAgentData?.platform || ''
  const touchPoints = Number(nav?.maxTouchPoints) || 0
  // The user-agent string decides first: it stays accurate when a browser or
  // test harness overrides it. Client hints only fill in an inconclusive one.
  if (/Android/.test(userAgent)) return 'android'
  if (/iPhone|iPad|iPod/.test(userAgent)) return 'apple'
  if (/Macintosh/.test(userAgent)) return touchPoints > 1 ? 'apple' : 'unknown'
  if (userAgent) return 'unknown'
  if (/Android/i.test(platform)) return 'android'
  if (/^iOS$/i.test(platform)) return 'apple'
  return 'unknown'
}

export function visibleWallets(availability, platform = walletPlatform()) {
  return {
    apple: Boolean(availability?.apple) && platform !== 'android',
    google: Boolean(availability?.google) && platform !== 'apple',
  }
}
