import { Helmet } from 'react-helmet-async'

const SITE_NAME = 'HafaPass'
const DEFAULT_TITLE = 'HafaPass — Your Pass to Every Event on Guam'
const DEFAULT_DESCRIPTION = 'Discover and book tickets for the best events on Guam. Nightlife, concerts, festivals, dining, sports, and more.'
const DEFAULT_IMAGE = 'https://hafapass.netlify.app/og-default.jpg'
const SITE_URL = 'https://hafapass.netlify.app'

export default function SEO({
  title,
  description = DEFAULT_DESCRIPTION,
  image = DEFAULT_IMAGE,
  url,
  type = 'website',
  jsonLd,
}) {
  const fullTitle = title ? `${title} | ${SITE_NAME}` : DEFAULT_TITLE
  const canonicalUrl = url || SITE_URL

  return (
    <Helmet>
      <title>{fullTitle}</title>
      <meta name="description" content={description} />

      {/* Open Graph */}
      <meta property="og:title" content={title || DEFAULT_TITLE} />
      <meta property="og:description" content={description} />
      <meta property="og:image" content={image} />
      <meta property="og:url" content={canonicalUrl} />
      <meta property="og:type" content={type} />
      <meta property="og:site_name" content={SITE_NAME} />

      {/* Twitter Card */}
      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content={title || DEFAULT_TITLE} />
      <meta name="twitter:description" content={description} />
      <meta name="twitter:image" content={image} />

      <link rel="canonical" href={canonicalUrl} />

      {/* JSON-LD Structured Data */}
      {jsonLd && (
        <script type="application/ld+json">
          {JSON.stringify(jsonLd)}
        </script>
      )}
    </Helmet>
  )
}
