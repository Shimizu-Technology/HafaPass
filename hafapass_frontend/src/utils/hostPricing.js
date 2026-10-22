import { formatMoneyCents } from './money'
import { quoteBuyerFeeCents } from './feeTerms'

// Organizer pricing for the public host page. Every number comes from the
// public `/config` response; nothing here assumes a rate. The fee math mirrors
// Commerce::ServiceFee, which checkout uses: per ticket, a percentage of the
// ticket price (rounded half up to the cent) plus the flat amount, times the
// quantity, and no fee at all when the tickets are free. The shared fixture
// serviceFeeParity.json is checked against both implementations.

export const MAX_TICKET_PRICE_CENTS = 10_000_00
export const MAX_QUANTITY = 1000

// Percent arrives as a decimal string from Rails ("5.0") or a number.
function percentToBasisPoints(value) {
  if (value === null || value === undefined || value === '' || typeof value === 'boolean') return null
  const number = Number(value)
  if (!Number.isFinite(number) || number < 0 || number > 100) return null
  return Math.round(number * 100)
}

function wholeCents(value) {
  if (value === null || value === undefined || value === '' || typeof value === 'boolean') return null
  const number = Number(value)
  return Number.isInteger(number) && number >= 0 ? number : null
}

function cleanText(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

// Returns null when the fee itself is unknown, so callers hide the specifics
// instead of showing a guess. Optional fields stay null when absent.
export function parseHostPricing(config) {
  if (!config || typeof config !== 'object') return null
  const basisPoints = percentToBasisPoints(config.service_fee_percent)
  const flatCents = wholeCents(config.service_fee_flat_cents)
  if (basisPoints === null || flatCents === null) return null
  const bearer = cleanText(config.processing_fee_bearer)
  return {
    basisPoints,
    flatCents,
    processingIncluded: bearer ? bearer === 'platform' : null,
    payoutScheduleText: cleanText(config.payout_schedule_text),
  }
}

export function formatPercent(basisPoints) {
  return `${Number((basisPoints / 100).toFixed(2))}%`
}

// "5% + $1.00 per paid ticket", "5% per paid ticket", "$1.00 per paid ticket".
export function describeFee({ basisPoints, flatCents }) {
  const parts = []
  if (basisPoints > 0) parts.push(formatPercent(basisPoints))
  if (flatCents > 0) parts.push(formatMoneyCents(flatCents))
  return parts.length ? `${parts.join(' + ')} per paid ticket` : 'No fee on tickets'
}

// Accepts what people type into a price box: "25", "12.5", "$1,250.00".
// Returns integer cents, or null when the value is not a usable price.
export function parsePriceInput(input) {
  if (typeof input !== 'string') return null
  const text = input.trim().replace(/^\$/, '').replace(/,/g, '').trim()
  if (!/^(\d+(\.\d{0,2})?|\.\d{1,2})$/.test(text)) return null
  const [dollars, fraction = ''] = text.split('.')
  const cents = Number(dollars || 0) * 100 + Number(fraction.padEnd(2, '0'))
  return cents <= MAX_TICKET_PRICE_CENTS ? cents : null
}

export function parseQuantityInput(input) {
  if (typeof input !== 'string' || !/^\d+$/.test(input.trim())) return null
  const quantity = Number(input.trim())
  return quantity >= 1 && quantity <= MAX_QUANTITY ? quantity : null
}

export function serviceFeeCents({ priceCents, quantity, pricing }) {
  if (priceCents <= 0 || quantity <= 0) return 0
  // Rounded per ticket, like checkout. Integer half-up rounding avoids float
  // drift (e.g. 5% of $10.10 is 50.5 cents, charged as 51 on every ticket).
  const perTicket = quoteBuyerFeeCents({ percent: pricing.basisPoints / 100, flatCents: pricing.flatCents }, priceCents).platformFeeCents
  return perTicket * quantity
}

// Both ways an organizer can handle the fee, for one order, before any card
// processing the organizer bears.
export function calculateHostPayout({ priceCents, quantity, pricing }) {
  const subtotalCents = priceCents * quantity
  const feeCents = serviceFeeCents({ priceCents, quantity, pricing })
  return {
    subtotalCents,
    feeCents,
    buyerPays: { buyerTotalCents: subtotalCents + feeCents, organizerReceivesCents: subtotalCents },
    // Checkout floors organizer proceeds at zero (OrderCreator#create_ledger!).
    organizerAbsorbs: { buyerTotalCents: subtotalCents, organizerReceivesCents: Math.max(subtotalCents - feeCents, 0) },
    feeExceedsPrice: feeCents > subtotalCents,
  }
}

const ORGANIZER_HOME = '/dashboard'

// Where the host call to action leads. The dashboard creates the organizer
// profile on first visit, so new accounts sign up with that as their return
// destination. Until Clerk has loaded (or without Clerk in local development)
// the dashboard's own protected route decides.
export function hostCtaTargets({ clerkEnabled, isLoaded, isSignedIn }) {
  if (clerkEnabled && isLoaded && !isSignedIn) {
    const returnTo = encodeURIComponent(ORGANIZER_HOME)
    return { primary: `/sign-up?returnTo=${returnTo}`, signIn: `/sign-in?returnTo=${returnTo}`, signedIn: false }
  }
  return { primary: ORGANIZER_HOME, signIn: null, signedIn: Boolean(clerkEnabled && isLoaded && isSignedIn) }
}
