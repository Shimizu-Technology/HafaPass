import { Link } from 'react-router-dom'
import { formatRegistrationAnswer } from '../../utils/eventToolFormat'
import { serviceDayString } from '../../utils/reEntryRules'

const dollars = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const quantity = new Intl.NumberFormat('en-US')
const money = cents => dollars.format(cents / 100)
const number = value => quantity.format(value)
const cell = 'px-3 py-3 align-top text-left'
const numeric = 'px-3 py-3 align-top text-right tabular-nums'

function Metrics({ items }) {
  return <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">
    {items.map(([label, value]) => <div key={label} className="rounded-xl border border-neutral-200 bg-white p-4">
      <dt className="text-neutral-700">{label}</dt>
      <dd className="mt-1 text-xl font-bold tabular-nums sm:text-2xl">{value}</dd>
    </div>)}
  </dl>
}

function Table({ label, children }) {
  return <div className="event-report-table overflow-x-auto rounded-xl border border-neutral-200 bg-white" tabIndex={0} role="region" aria-label={label}>
    <table className="w-full border-collapse text-base">
      <caption className="sr-only">{label}</caption>
      {children}
    </table>
  </div>
}

export function SalesReport({ data }) {
  const { summary, sales_by_tier: rows } = data
  const columns = [
    ['tickets_sold', 'Sold'], ['tickets_refunded_or_cancelled', 'Refunded or cancelled'],
    ['gross_cents', 'Gross sales'], ['discount_cents', 'Discounts'], ['net_cents', 'Net sales'],
    ['remaining_capacity', 'Spaces left'],
  ]
  return <>
    <Metrics items={[
      ['Gross sales', money(summary.gross_sales_cents)], ['Net sales', money(summary.net_sales_cents)],
      ['Refunds', money(summary.total_refunded_cents)], ['Orders', number(summary.unique_orders)],
    ]} />
    <p className="text-neutral-700">Net sales are what buyers paid after discounts and refunds. Spaces left are shared across all prices for a ticket type.</p>
    {rows.length === 0 ? <p>No ticket sales match these filters.</p>
      : <Table label="Ticket sales by price window">
        <thead className="bg-neutral-100"><tr>
          <th scope="col" className={cell}>Ticket type</th><th scope="col" className={cell}>Price window</th>
          {columns.map(([key, label]) => <th scope="col" key={key} className={numeric}>{label}</th>)}
        </tr></thead>
        <tbody className="divide-y divide-neutral-200">{rows.map(row =>
          <tr key={JSON.stringify([row.ticket_type_id, row.pricing_tier_id, row.tier_name, row.unit_price_cents])}>
            <th scope="row" className={`${cell} min-w-28 break-words`}>{row.ticket_type_name}</th>
            <td className={`${cell} min-w-24`}>{row.tier_name}<span className="block text-neutral-700">{money(row.unit_price_cents)}</span></td>
            {columns.map(([key]) => <td key={key} className={numeric}>{key.endsWith('_cents') ? money(row[key]) : number(row[key])}</td>)}
          </tr>
        )}</tbody>
      </Table>}
  </>
}

function Bar({ percent }) {
  return <span className="event-report-bar block h-3 overflow-hidden rounded-sm bg-neutral-200" aria-hidden="true">
    <span className="block h-full bg-brand-800" style={{ width: `${percent}%` }} />
  </span>
}

export function AttendanceReport({ data, event = null }) {
  const peak = Math.max(1, ...data.pace.map(bucket => bucket.count))
  const dates = new Set(data.pace.map(bucket => bucket.bucket_start.slice(0, 10)))
  const reEntry = data.re_entry
  const showReEntry = Boolean(reEntry && (reEntry.mode !== 'off' || reEntry.exits > 0 || reEntry.re_entries > 0 || reEntry.by_day?.length > 0))
  const isCooldown = reEntry?.mode === 'cooldown'
  const isExitScan = reEntry?.mode === 'exit_scan'
  const multiDay = (reEntry?.by_day?.length || 0) > 1
  const currentServiceDay = reEntry?.current_service_day || serviceDayString(Date.now(), {
    timezone: data.timezone || event?.timezone,
    starts_at: event?.starts_at ?? data.starts_at,
    ends_at: event?.ends_at ?? data.ends_at,
    doors_open_at: event?.doors_open_at ?? data.doors_open_at,
    re_entry_rollover_hour: reEntry?.rollover_hour,
  })
  const modeLabel = isExitScan
    ? 'Exit scan (in & out)'
    : isCooldown
      ? `Cool-down (${reEntry.cooldown_minutes || 15} min)`
      : 'Off (single entry)'
  const summaryOccupancyLabel = isCooldown ? 'Admitted' : (multiDay ? 'Tickets inside / active' : 'Tickets inside')
  const summaryOccupancyValue = isCooldown ? number(reEntry?.entries || 0) : number(reEntry?.current_headcount || 0)
  const dayOccupancyHeader = isCooldown ? 'Admitted' : 'Tickets inside / status'
  return <>
    <Metrics items={[
      ['Expected', number(data.total_active_tickets)], ['Checked in', number(data.checked_in_count)],
      ['Still to check in', number(data.remaining_count)], ['Check-in rate', `${data.check_in_rate}%`],
    ]} />
    {showReEntry && (
      <section aria-labelledby="re-entry-headcount" className="space-y-4 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <div>
            <h4 id="re-entry-headcount" className="text-lg font-bold">Re-entry &amp; Tickets Inside</h4>
            <p className="mt-0.5 text-xs text-neutral-600">Counts admitted tickets currently inside, not verified unique people.</p>
          </div>
          <span className="rounded-full bg-neutral-100 px-3 py-1 text-xs font-semibold text-neutral-800">Mode: {modeLabel}</span>
        </div>
        <dl className="grid grid-cols-2 gap-3 lg:grid-cols-5">
          {[
            ['Entries', number(reEntry.entries || 0)],
            ['Exits', number(reEntry.exits || 0)],
            ['Re-entries', number(reEntry.re_entries || 0)],
            [summaryOccupancyLabel, summaryOccupancyValue],
            [isCooldown ? 'Peak admitted' : 'Peak tickets inside', reEntry.peak_headcount > 0
              ? `${number(reEntry.peak_headcount)}${reEntry.peak_headcount_label ? ` · ${reEntry.peak_headcount_label}` : ''}`
              : '0'],
          ].map(([label, value]) => (
            <div key={label} className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
              <dt className="text-xs font-medium text-neutral-700">{label}</dt>
              <dd className="mt-1 text-lg font-bold tabular-nums text-neutral-950">{value}</dd>
            </div>
          ))}
        </dl>
        {reEntry.by_day?.length > 0 && (
          <>
            <ul aria-label="Daily tickets inside and re-entry summary" className="space-y-2 sm:hidden print:hidden">
              {reEntry.by_day.map(day => {
                const rowServiceDay = day.current_service_day || currentServiceDay
                const isPastDay = Boolean(day.day && rowServiceDay && day.day < rowServiceDay)
                const dayStatus = isCooldown
                  ? `${number(day.entries)} admitted`
                  : isPastDay
                    ? `${number(day.entries)} entered`
                    : number(day.current_headcount)
                return (
                  <li key={`${day.event_id || 'e'}-${day.day}`} className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                    <p className="font-bold text-neutral-950">{day.event_title || day.label || day.day}</p>
                    {day.event_title && <p className="text-xs text-neutral-600">{day.label || day.day}</p>}
                    <dl className="mt-2 grid grid-cols-2 gap-2 text-sm">
                      <div><dt className="text-xs text-neutral-600">Entries</dt><dd className="font-semibold tabular-nums">{number(day.entries)}</dd></div>
                      <div><dt className="text-xs text-neutral-600">Exits</dt><dd className="font-semibold tabular-nums">{number(day.exits)}</dd></div>
                      <div><dt className="text-xs text-neutral-600">Re-entries</dt><dd className="font-semibold tabular-nums">{number(day.re_entries)}</dd></div>
                      <div><dt className="text-xs text-neutral-600">Overrides</dt><dd className="font-semibold tabular-nums">{number(day.overrides || 0)}</dd></div>
                      <div><dt className="text-xs text-neutral-600">{isCooldown || isPastDay ? 'Entered' : 'Tickets inside'}</dt><dd className="font-semibold tabular-nums">{dayStatus}</dd></div>
                      <div><dt className="text-xs text-neutral-600">{isCooldown ? 'Peak admitted' : 'Peak tickets inside'}</dt><dd className="font-semibold tabular-nums">{number(day.peak_headcount)}{day.peak_headcount_label ? ` · ${day.peak_headcount_label}` : ''}</dd></div>
                    </dl>
                  </li>
                )
              })}
            </ul>
            <div className="hidden sm:block print:block">
              <Table label="Daily tickets inside and re-entry breakdown">
                <thead className="bg-neutral-100"><tr>
                  <th scope="col" className={cell}>Day</th>
                  <th scope="col" className={numeric}>Entries</th>
                  <th scope="col" className={numeric}>Exits</th>
                  <th scope="col" className={numeric}>Re-entries</th>
                  <th scope="col" className={numeric}>Overrides</th>
                  <th scope="col" className={numeric}>{dayOccupancyHeader}</th>
                  <th scope="col" className={numeric}>{isCooldown ? 'Peak admitted' : 'Peak tickets inside'}</th>
                </tr></thead>
                <tbody className="divide-y divide-neutral-200">
                  {reEntry.by_day.map(day => {
                    const rowServiceDay = day.current_service_day || currentServiceDay
                    const isPastDay = Boolean(day.day && rowServiceDay && day.day < rowServiceDay)
                    const dayCell = isCooldown
                      ? number(day.entries)
                      : isPastDay
                        ? `${number(day.entries)} entered`
                        : number(day.current_headcount)
                    return (
                      <tr key={`${day.event_id || 'e'}-${day.day}`}>
                        <th scope="row" className={`${cell} min-w-28 break-words`}>
                          {day.event_title || day.label || day.day}
                          {day.event_title && <span className="block text-xs font-normal text-neutral-600">{day.label || day.day}</span>}
                        </th>
                        <td className={numeric}>{number(day.entries)}</td>
                        <td className={numeric}>{number(day.exits)}</td>
                        <td className={numeric}>{number(day.re_entries)}</td>
                        <td className={numeric}>{number(day.overrides || 0)}</td>
                        <td className={numeric}>{dayCell}</td>
                        <td className={numeric}>
                          {number(day.peak_headcount)}
                          {day.peak_headcount_label && <span className="block text-xs font-normal text-neutral-600">{day.peak_headcount_label}</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </Table>
            </div>
          </>
        )}
      </section>
    )}
    <section aria-labelledby="attendance-by-ticket" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h4 id="attendance-by-ticket" className="text-lg font-bold">Check-ins by Ticket Type</h4>
      {data.by_ticket_type.length === 0 ? <p>No active tickets match these filters.</p>
        : <ul className="space-y-4">{data.by_ticket_type.map(type => <li key={type.ticket_type_id} className="space-y-1.5">
          <div className="flex flex-wrap justify-between gap-x-3">
            <span className="break-words font-semibold">{type.ticket_type_name}</span>
            <span className="tabular-nums">{number(type.checked_in_count)} of {number(type.total_active_tickets)} · {type.check_in_rate}%</span>
          </div>
          <Bar percent={type.check_in_rate} />
        </li>)}</ul>}
    </section>
    <section aria-labelledby="door-pace" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h4 id="door-pace" className="text-lg font-bold">Door Check-in Pace</h4>
      <p className="text-neutral-700">Check-ins every 30 minutes · {data.timezone}</p>
      {data.pace.length === 0 ? <p>No check-ins recorded for these tickets yet.</p>
        : <ol className="space-y-2">{data.pace.map(bucket => <li key={bucket.bucket_start}
          className="grid grid-cols-[minmax(5rem,auto)_1fr_2.5rem] items-center gap-3">
          <time dateTime={bucket.bucket_start}>{dates.size > 1 && `${bucket.bucket_start.slice(5, 10).replace('-', '/')} · `}{bucket.label}</time>
          <Bar percent={100 * bucket.count / peak} />
          <span className="text-right font-semibold tabular-nums">{number(bucket.count)}</span>
        </li>)}</ol>}
    </section>
  </>
}

export function DemographicsReport({ questions, answerLink }) {
  if (questions.length === 0) return <p>This event has no registration questions yet.</p>

  return <div className="grid items-start gap-4 xl:grid-cols-2">
    {questions.map(question => <section key={question.question_id} aria-labelledby={`question-${question.question_id}`}
      className="min-w-0 space-y-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h4 id={`question-${question.question_id}`} className="break-words text-lg font-bold">{question.prompt}</h4>
      <p className="text-neutral-700">{number(question.total_responses)} answered · {number(question.blank_or_unanswered_count)} unanswered · Asked per {question.scope}</p>
      {question.kind === 'multi_select' && <p className="text-neutral-700">People could choose more than one answer.</p>}
      {question.buckets.length === 0 ? <p>No answers match these filters.</p>
        : <ul className="space-y-1.5">{question.buckets.map(bucket => <li key={String(bucket.value)}>
          <Link to={answerLink(question, bucket)}
            aria-label={`Show registrations for ${question.prompt}: ${bucket.label} (${bucket.count})`}
            className="block min-h-12 space-y-1.5 rounded-md border border-transparent px-2.5 py-2 text-neutral-950 hover:border-brand-700 hover:bg-brand-50">
            <span className="flex items-baseline justify-between gap-3">
              <span className="min-w-0 break-words font-semibold underline decoration-brand-800 underline-offset-2">{bucket.label}</span>
              <span className="shrink-0 tabular-nums">{number(bucket.count)} · {bucket.percentage}%</span>
            </span>
            <Bar percent={bucket.percentage} />
          </Link>
        </li>)}</ul>}
      {question.other_count > 0 && <p className="text-neutral-700">{number(question.other_count)} responses with less common answers.</p>}
    </section>)}
  </div>
}

function RegistrationDetails({ row, questions, answers }) {
  return [
    ...(row.buyer_name && row.buyer_name !== row.attendee_name ? [['Buyer', row.buyer_name]] : []),
    ['Price window', row.pricing_tier || 'Base price'], ['Order status', row.order_status_label],
    ['Check-in status', row.status === 'checked_in' ? 'Checked in' : 'Not checked in'],
    ...questions.filter(question => answers.has(question.question_id)).map(question =>
      [question.prompt, formatRegistrationAnswer(answers.get(question.question_id))]),
  ].map(([label, value], index) => <div className="min-w-0" key={`${label}-${index}`}>
    <dt className="break-words font-medium text-neutral-700">{label}</dt>
    <dd className="break-words">{value}</dd>
  </div>)
}

export function RegistrationReport({ data, changePage }) {
  const questions = data.registration_questions || []
  const { attendees, meta } = data
  if (attendees.length === 0) return <p>No registrations match these filters.</p>
  const rows = attendees.map(row => ({
    row,
    name: row.attendee_name || row.buyer_name || '—',
    answers: new Map((row.registration_answers || []).map(answer => [answer.question_id, answer.value])),
  }))

  return <>
    <p className="text-neutral-700">{number(meta.total_count)} matching registrations{meta.total_pages > 1 && ` · Page ${meta.current_page} of ${meta.total_pages}`}</p>
    <ul aria-label="Registrations and custom answers" className="space-y-3 sm:hidden print:hidden">
      {rows.map(({ row, name, answers }) => <li key={row.id} className="rounded-xl border border-neutral-200 bg-white p-4">
        <h4 className="break-words text-lg font-bold">{name}</h4>
        <p className="mt-1 break-words text-neutral-700">{row.ticket_type}</p>
        <dl className="mt-3 grid grid-cols-2 gap-3 border-t border-neutral-200 pt-3">
          <RegistrationDetails row={row} questions={questions} answers={answers} />
        </dl>
      </li>)}
    </ul>
    <div className="hidden sm:block print:block">
      <Table label="Registrations and custom answers">
        <thead className="bg-neutral-100"><tr>
          {['Attendee', 'Buyer', 'Ticket type', 'Price window', 'Order status', 'Check-in status'].map(label => <th scope="col" key={label} className={cell}>{label}</th>)}
          {questions.map(question => <th scope="col" key={question.question_id} className={`${cell} min-w-32 break-words`}>{question.prompt}</th>)}
        </tr></thead>
        <tbody className="divide-y divide-neutral-200">{rows.map(({ row, name, answers }) =>
          <tr key={row.id}>
            <th scope="row" className={`${cell} min-w-28 break-words`}>{name}</th>
            <td className={cell}>{row.buyer_name && row.buyer_name !== name ? row.buyer_name : '—'}</td>
            <td className={cell}>{row.ticket_type}</td>
            <td className={cell}>{row.pricing_tier || 'Base price'}</td>
            <td className={cell}>{row.order_status_label}</td>
            <td className={cell}>{row.status === 'checked_in' ? 'Checked in' : 'Not checked in'}</td>
            {questions.map(question => <td key={question.question_id} className={`${cell} max-w-64 break-words`}>
              {formatRegistrationAnswer(answers.get(question.question_id))}
            </td>)}
          </tr>)}</tbody>
      </Table>
    </div>
    {meta.total_pages > 1 && <nav className="event-report-controls flex flex-wrap gap-3" aria-label="Registration pages">
      <button type="button" disabled={!meta.prev_page} onClick={() => changePage(meta.prev_page)} className="btn-secondary min-h-12 text-base">Previous page</button>
      <button type="button" disabled={!meta.next_page} onClick={() => changePage(meta.next_page)} className="btn-secondary min-h-12 text-base">Next page</button>
    </nav>}
  </>
}

export function PayoutsReport({ series, eventId }) {
  return <div className="grid gap-4 sm:grid-cols-2">
    <section className="space-y-2 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h4 className="text-lg font-bold">Event payout</h4>
      <p className="text-neutral-700">See what has been paid out and download the event statement.</p>
      <Link className="inline-flex min-h-12 items-center font-semibold text-brand-800 underline" to={`/dashboard/events/${eventId}/analytics#settlement`}>Open payout & statement</Link>
    </section>
    <section className="space-y-2 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h4 className="text-lg font-bold">Revenue splits</h4>
      {series?.length ? <ul>{series.map(item => <li key={item.id}>
        <Link className="inline-flex min-h-12 items-center break-all font-semibold text-brand-800 underline" to={`/dashboard/series/${item.id}/report`}>{item.name} report</Link>
      </li>)}</ul> : <p className="text-neutral-700">There are no series splits to show for this event.</p>}
    </section>
  </div>
}
