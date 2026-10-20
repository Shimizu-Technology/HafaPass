import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { axisLabelIndexes, axisTicks, compactNumber, formatDay } from './chartScale'

const HEIGHT = 200
const AXIS_BAND = 28
const TOP_PAD = 22
const LEFT_AXIS = 44
const MAX_COLUMN = 24
const RADIUS = 4

// A column whose data end is rounded and whose baseline end stays square.
function columnPath(x, y, width, height) {
  if (height <= 0) return ''
  const radius = Math.min(RADIUS, width / 2, height)
  const bottom = y + height
  return `M${x},${bottom}V${y + radius}Q${x},${y} ${x + radius},${y}H${x + width - radius}Q${x + width},${y} ${x + width},${y + radius}V${bottom}Z`
}

function useWidth(ref, fallback = 640) {
  const [width, setWidth] = useState(fallback)
  useLayoutEffect(() => {
    const element = ref.current
    if (!element) return undefined
    const measure = () => { if (element.clientWidth > 0) setWidth(element.clientWidth) }
    measure()
    if (typeof ResizeObserver === 'undefined') return undefined
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [ref])
  return width
}

// One series of daily columns. Hover or focus a day to read it; the arrow
// keys move between days. Callers pass `days` as { date: 'YYYY-MM-DD', value }.
export default function DailyColumnChart({ days, label, formatValue = String, integer = false, unitLabel }) {
  const containerRef = useRef(null)
  const width = useWidth(containerRef)
  const [active, setActive] = useState(null)
  const [keyboard, setKeyboard] = useState(false)
  const titleId = useId()
  const liveId = useId()

  useEffect(() => { setActive(index => (index == null || index < days.length ? index : null)) }, [days.length])

  const values = days.map(day => day.value)
  const max = Math.max(0, ...values)
  const ticks = axisTicks(max, { integer })
  const top = ticks.at(-1) || 1
  const plotWidth = Math.max(1, width - LEFT_AXIS - 4)
  const plotHeight = HEIGHT - TOP_PAD
  const band = plotWidth / Math.max(days.length, 1)
  // Leave air between columns: the 2px surface gap at minimum, capped width.
  const columnWidth = Math.max(1, Math.min(MAX_COLUMN, band * 0.7, band - 2))
  const y = value => TOP_PAD + plotHeight - (value / top) * plotHeight
  const xCenter = index => LEFT_AXIS + band * index + band / 2
  const peakIndex = max > 0 ? values.indexOf(max) : -1
  const shownLabels = new Set(axisLabelIndexes(days.length, plotWidth))
  const current = active != null ? days[active] : null
  const total = values.reduce((sum, value) => sum + value, 0)
  const summary = days.length === 0 ? 'No days to show.'
    : `${days.length} day${days.length === 1 ? '' : 's'} from ${formatDay(days[0].date)} to ${formatDay(days.at(-1).date)}. Total ${formatValue(total)}. Busiest day ${formatDay(days[peakIndex]?.date || days[0].date)} with ${formatValue(max)}.`

  const onKeyDown = event => {
    if (!days.length) return
    const moves = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }
    let next = null
    if (event.key in moves) next = Math.min(days.length - 1, Math.max(0, (active ?? days.length - 1) + (active == null ? 0 : moves[event.key])))
    if (event.key === 'Home') next = 0
    if (event.key === 'End') next = days.length - 1
    if (event.key === 'Escape') { setActive(null); return }
    if (next == null) return
    event.preventDefault()
    setKeyboard(true)
    setActive(next)
  }

  const onPointerMove = event => {
    const rect = event.currentTarget.getBoundingClientRect()
    const scale = rect.width > 0 ? width / rect.width : 1
    const x = (event.clientX - rect.left) * scale - LEFT_AXIS
    if (x < 0 || x > plotWidth) return
    setKeyboard(false)
    setActive(Math.min(days.length - 1, Math.max(0, Math.floor(x / band))))
  }

  const tooltipLeft = current ? Math.min(Math.max(xCenter(active), 64), width - 64) : 0

  return (
    <div ref={containerRef} className="relative w-full min-w-0">
      <p id={titleId} className="sr-only">{label}. {summary}</p>
      <div
        role="group"
        tabIndex={0}
        aria-labelledby={titleId}
        aria-describedby={liveId}
        onKeyDown={onKeyDown}
        onFocus={() => { if (active == null && days.length) { setKeyboard(true); setActive(days.length - 1) } }}
        onBlur={() => { if (keyboard) setActive(null) }}
        className="rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
      >
        <svg
          width="100%"
          height={HEIGHT + AXIS_BAND}
          viewBox={`0 0 ${width} ${HEIGHT + AXIS_BAND}`}
          aria-hidden="true"
          className="block touch-pan-y select-none overflow-visible"
          onPointerMove={onPointerMove}
          onPointerDown={onPointerMove}
          onPointerLeave={() => { if (!keyboard) setActive(null) }}
        >
          {ticks.map(tick => (
            <g key={tick}>
              <line x1={LEFT_AXIS} x2={width - 4} y1={y(tick)} y2={y(tick)} className="stroke-neutral-200" strokeWidth="1" shapeRendering="crispEdges" />
              <text x={LEFT_AXIS - 8} y={y(tick)} dy="0.32em" textAnchor="end" className="fill-neutral-600 text-[11px] tabular-nums">{compactNumber(tick)}</text>
            </g>
          ))}
          {days.map((day, index) => {
            const columnHeight = Math.max(0, TOP_PAD + plotHeight - y(day.value))
            const x = xCenter(index) - columnWidth / 2
            return <path key={day.date} d={columnPath(x, y(day.value), columnWidth, columnHeight)} className={`transition-[fill] duration-150 ease-out-strong ${active === index ? 'fill-brand-700' : 'fill-brand-500'}`} />
          })}
          {peakIndex >= 0 && active == null && (
            <text x={xCenter(peakIndex)} y={y(max) - 6} textAnchor={peakIndex === 0 ? 'start' : peakIndex === days.length - 1 ? 'end' : 'middle'} className="fill-neutral-700 text-[11px] font-semibold">{formatValue(max)}</text>
          )}
          {current && <line x1={xCenter(active)} x2={xCenter(active)} y1={TOP_PAD} y2={TOP_PAD + plotHeight} className="stroke-neutral-400" strokeWidth="1" shapeRendering="crispEdges" />}
          {days.map((day, index) => shownLabels.has(index) && (
            <text key={day.date} x={xCenter(index)} y={HEIGHT + 18} textAnchor={days.length > 1 && index === 0 ? 'start' : days.length > 1 && index === days.length - 1 ? 'end' : 'middle'} className="fill-neutral-600 text-[11px]">{formatDay(day.date)}</text>
          ))}
        </svg>
      </div>
      {current && (
        <div
          aria-hidden="true"
          className="pointer-events-none absolute top-0 z-10 -translate-x-1/2 whitespace-nowrap rounded-lg border border-neutral-200 bg-white px-3 py-2 text-xs shadow-card"
          style={{ left: tooltipLeft }}
        >
          <p className="text-sm font-semibold text-neutral-950">{formatValue(current.value)}{unitLabel ? <span className="font-normal text-neutral-600"> {unitLabel}</span> : null}</p>
          <p className="text-neutral-600">{formatDay(current.date, { weekday: 'short', month: 'short', day: 'numeric' })}</p>
        </div>
      )}
      <p id={liveId} aria-live="polite" className="sr-only">
        {current ? `${formatDay(current.date, { weekday: 'long', month: 'long', day: 'numeric' })}: ${formatValue(current.value)}${unitLabel ? ` ${unitLabel}` : ''}` : 'Use the left and right arrow keys to read each day.'}
      </p>
    </div>
  )
}
