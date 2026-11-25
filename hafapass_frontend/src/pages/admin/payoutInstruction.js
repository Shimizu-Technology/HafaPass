import { money } from './adminOperations'

// The bank instruction comes from the payout the API actually created: the
// organization-wide balance can cap it below the statement, and backup
// withholding reduces what is sent.
export function payoutInstruction(payout, row) {
  const cur = payout.currency || row.currency
  const gross = money(payout.amount_cents, cur)
  const sent = payout.disbursement_cents ?? payout.amount_cents
  const withheld = payout.withheld_cents > 0 ? `${money(payout.withheld_cents, cur)} withheld for taxes` : ''
  const where = `${row.organization.name}'s approved bank account for ${row.event.title}`
  if (payout.status === 'held') return `Payout #${payout.id} (${gross}) is on hold. Do not send money until the hold is released.`
  if (payout.status === 'failed') return `Payout #${payout.id} did not go through. Nothing was reserved; check the payout list for the reason.`
  if (payout.status === 'paid') return `Payout #${payout.id} of ${money(sent, cur)} is already recorded as paid.`
  if (sent === 0) return `Payout #${payout.id} (${gross}) is withholding only: ${withheld || 'the whole amount is withheld'} and nothing goes to the bank. Record it in Payouts with the withholding-only reference.`
  return `Send ${money(sent, cur)} to ${where}${withheld ? ` (${gross} gross, ${withheld})` : ''}. Then choose Record transfer with the bank reference.`
}
