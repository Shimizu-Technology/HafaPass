import { Link } from 'react-router-dom'
import { ChevronLeft } from 'lucide-react'
import { WORKSPACE_WIDTHS } from '../utils/workspace'

export function WorkspacePage({ width = 'standard', as: Element = 'div', className = '', children, ...props }) {
  return (
    <Element className={`mx-auto w-full min-w-0 ${WORKSPACE_WIDTHS[width] || WORKSPACE_WIDTHS.standard} px-4 py-8 sm:px-6 lg:px-8 ${className}`} {...props}>
      {children}
    </Element>
  )
}

// One back-link style for every workspace page: chevron + "Back to …" label.
export function BackLink({ to = '/dashboard', children = 'Back to dashboard', className = '', ...props }) {
  return (
    <Link
      to={to}
      className={`-ml-1 inline-flex min-h-11 items-center gap-1 rounded-lg px-1 text-sm font-medium text-brand-700 transition-colors hover:text-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${className}`}
      {...props}
    >
      <ChevronLeft aria-hidden="true" className="h-4 w-4 shrink-0" />
      {children}
    </Link>
  )
}

export function PageHeader({ title, titleId, eyebrow, description, titleAccessory, actions, back, children, className = '' }) {
  return (
    <header className={`mb-8 ${className}`}>
      {back && <div className="mb-3">{back}</div>}
      <div className="flex min-w-0 flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 flex-1">
          {eyebrow && <p className="text-sm font-semibold uppercase tracking-wider text-brand-600">{eyebrow}</p>}
          <div className="flex min-w-0 items-center gap-2">
            <h1 id={titleId} className="min-w-0 break-words text-2xl font-bold text-neutral-950 sm:text-3xl">{title}</h1>
            {titleAccessory}
          </div>
          {description && <p className="mt-1 text-sm text-neutral-600 sm:text-base">{description}</p>}
          {children}
        </div>
        {actions && <div className="flex min-w-0 flex-wrap items-center gap-2 lg:shrink-0 lg:justify-end">{actions}</div>}
      </div>
    </header>
  )
}
