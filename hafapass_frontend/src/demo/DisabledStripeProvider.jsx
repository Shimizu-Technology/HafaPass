// Replaced only at build time in fictional previews. A payment component being
// rendered here is an implementation error; fail closed rather than load Stripe.
export default function DisabledStripeProvider() {
  throw new Error('Payments are disabled in demo previews')
}
export function PaymentLoadFailure() { return null }
