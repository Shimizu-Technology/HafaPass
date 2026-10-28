// Short public-page introduction. Keep controls on the light surface below.
export default function BuyerTitleBand({ title, description, compact = false }) {
  return <div className="bg-brand-950 text-white">
    <div className={`mx-auto px-4 py-5 sm:px-6 sm:py-9 ${compact ? 'max-w-3xl' : 'max-w-6xl lg:px-8'}`}>
      <h1 className="font-display text-3xl font-bold tracking-tight [overflow-wrap:anywhere] sm:text-4xl">{title}</h1>
      {description && <p className="mt-2 max-w-2xl text-base leading-relaxed text-brand-100">{description}</p>}
    </div>
  </div>
}
