// Two masked halves meet at the perforation. The notch follows the seam even
// when text wraps or a form shows validation. Keep focusable content inset;
// cards put their focus outline on the unmasked outer link.
export function TicketTop({ children, className = '' }) {
  return <div className={`ticket-notch ticket-top ${className}`}>{children}<TearLine /></div>
}

export function TicketStub({ children, className = '' }) {
  return <div className={`ticket-notch ticket-stub ${className}`}>{children}</div>
}

export function TearLine() {
  return <div aria-hidden="true" className="ticket-tear" />
}

export default function Ticket({ children, stub, className = '', topClassName = '', stubClassName = '' }) {
  return <div className={`ticket ${className}`}>
    <TicketTop className={topClassName}>{children}</TicketTop>
    <TicketStub className={stubClassName}>{stub}</TicketStub>
  </div>
}
