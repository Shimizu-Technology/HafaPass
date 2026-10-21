import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { Linter } from 'eslint'
import { describe, expect, it } from 'vitest'

const pages = ['EventDetailPage', 'EventsPage', 'HomePage', 'CheckoutPage', 'OrderConfirmationPage', 'TicketPage', 'MyTicketsPage', 'OrderRecoveryPage', 'TicketTransferAcceptPage', 'PolicyPage', 'HostPage', 'OrganizerPage', 'VenuePage', 'SavedPage', 'CollectionsPage', 'CollectionPage', 'PrivatePreviewPage', 'SignInPage', 'SignUpPage']
const components = ['EventCard', 'TicketTypesSection', 'SeatSelector', 'TransferTicketDialog', 'PendingTransfer', 'WaitlistForm', 'WhosGoing', 'PaymentForm', 'PaymentModeBanner', 'MarketplacePagination', 'Footer', 'NotFound', 'QRCode', 'EnvironmentBanner', 'Layout']
// ServiceCheck also owns the staff-only offline scanner, which retains English copy.
const files = [...pages.map(name => `pages/${name}.jsx`), ...components.map(name => `components/${name}.jsx`)]
// Product names, example card numbers and literal currency symbols stay as written.
const literalNames = new Set(['HåfaPass', 'Håfa', 'Pass', '4242 4242 4242 4242'])

describe('buyer interface extraction', () => {
  for (const file of files) it(`${file} has no hardcoded English JSX copy`, () => {
    const source = readFileSync(resolve(import.meta.dirname, '..', file), 'utf8')
    const linter = new Linter()
    const results = linter.verify(source, [{
      files: ['**/*.jsx'],
      languageOptions: { parserOptions: { ecmaVersion: 'latest', sourceType: 'module', ecmaFeatures: { jsx: true } } },
      plugins: { extraction: { rules: { copy: { create(context) {
        const check = (node, text) => {
          if (/[a-zA-Z]{2}/.test(text) && !literalNames.has(text.trim())) context.report({ node, message: `Extract buyer copy: ${text.trim()}` })
        }
        return {
          JSXText(node) { check(node, node.value) },
          JSXAttribute(node) {
            if (['aria-label', 'placeholder', 'alt', 'title'].includes(node.name.name) && node.value?.type === 'Literal') check(node, node.value.value)
          },
          CallExpression(node) {
            if (node.callee.name !== 't' || node.arguments[1]?.type !== 'ObjectExpression') return
            for (const property of node.arguments[1].properties) {
              if (property.key?.name === 'defaultValue' && typeof property.value?.value === 'string' && property.value?.type === 'Literal') {
                context.report({ node: property.value, message: 'Extract buyer copy from defaultValue' })
              }
            }
          },
        }
      } } } } },
      rules: { 'extraction/copy': 'error' },
    }], { filename: file })
    expect(results.map(result => `${result.line}: ${result.message}`)).toEqual([])
  })
})
