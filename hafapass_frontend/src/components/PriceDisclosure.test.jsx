import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { AllInPriceNote, SellerLine } from './PriceDisclosure'
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: (key, options) => options ? `${key} ${JSON.stringify(options)}` : key }) }))

const paid = { price_cents: 2500, all_in_price_cents: 2725, service_fee_cents: 225, quantity_remaining: 5, on_sale: true }

describe('price disclosures', () => {
  it('names the organizer as seller and the platform as ticketing service', () => {
    render(<SellerLine seller={{ seller_name: 'Island Nights', ticketing_service: 'HåfaPass' }} />)
    expect(screen.getByTestId('seller-line')).toHaveTextContent('pricing.sellerLine {"seller":"Island Nights","platform":"HåfaPass"}')
  })
  it('renders nothing without a seller', () => {
    const { container } = render(<SellerLine seller={null} />)
    expect(container).toBeEmptyDOMElement()
  })
  it('explains what the fee pays for, including card processing when the platform covers it', () => {
    render(<AllInPriceNote ticketTypes={[paid]} includesProcessing platform="HåfaPass" />)
    expect(screen.getByTestId('all-in-note')).toHaveTextContent('pricing.allInNote {"platform":"HåfaPass"}')
  })
  it('says there are no added fees when the organizer absorbs them, and stays quiet for free events', () => {
    const { rerender, container } = render(<AllInPriceNote ticketTypes={[{ ...paid, all_in_price_cents: 2500, service_fee_cents: 0 }]} />)
    expect(screen.getByTestId('all-in-note')).toHaveTextContent('pricing.noAddedFees')
    rerender(<AllInPriceNote ticketTypes={[{ price_cents: 0, quantity_remaining: 5 }]} />)
    expect(container).toBeEmptyDOMElement()
  })
  it('never calls the service fee a tax', () => {
    render(<AllInPriceNote ticketTypes={[paid]} />)
    expect(screen.getByTestId('all-in-note').textContent).not.toMatch(/tax/i)
  })
})
