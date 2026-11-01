import { Helmet } from 'react-helmet-async'
import { useInRouterContext, useLocation } from 'react-router-dom'
import { PUBLIC_WEB_URL } from '../utils/site'

const SITE_NAME = 'HåfaPass'
const DEFAULT_TITLE = 'HåfaPass — Events and Tickets on Guam'
const DEFAULT_DESCRIPTION = 'Discover events on Guam, buy tickets, and check in with your phone.'
const DEFAULT_IMAGE = `${PUBLIC_WEB_URL}/og-default.jpg`

function RoutedSEO(props) {
  return <SEOTags {...props} pathname={useLocation().pathname} />
}

// The canonical URL defaults to the current page, never the site root. Pages
// that must stay out of search results publish no canonical or og:url at all.
export default function SEO(props) {
  return useInRouterContext() ? <RoutedSEO {...props} /> : <SEOTags {...props} pathname={globalThis.location?.pathname || '/'} />
}

function SEOTags({
  title,
  description = DEFAULT_DESCRIPTION,
  image = DEFAULT_IMAGE,
  url,
  type = 'website',
  jsonLd,
  noIndex = false,
  noSocial = false,
  pathname,
}) {
  const fullTitle = title ? `${title} | ${SITE_NAME}` : DEFAULT_TITLE
  const canonicalUrl = noIndex ? null : (url || `${PUBLIC_WEB_URL}${pathname === '/' ? '' : pathname}`)

  return (
    <Helmet>
      <title>{fullTitle}</title>
      <meta name="description" content={description} />
      {noIndex && <meta name="robots" content="noindex, nofollow, noarchive" />}

      {/* Open Graph */}
      {!noSocial && <meta property="og:title" content={title || DEFAULT_TITLE} />}
      {!noSocial && <meta property="og:description" content={description} />}
      {!noSocial && <meta property="og:image" content={image} />}
      {!noSocial && image === DEFAULT_IMAGE && <meta property="og:image:width" content="1200" />}
      {!noSocial && image === DEFAULT_IMAGE && <meta property="og:image:height" content="630" />}
      {!noSocial && canonicalUrl && <meta property="og:url" content={canonicalUrl} />}
      {!noSocial && <meta property="og:type" content={type} />}
      {!noSocial && <meta property="og:site_name" content={SITE_NAME} />}

      {/* Twitter Card */}
      {!noSocial && <meta name="twitter:card" content="summary_large_image" />}
      {!noSocial && <meta name="twitter:title" content={title || DEFAULT_TITLE} />}
      {!noSocial && <meta name="twitter:description" content={description} />}
      {!noSocial && <meta name="twitter:image" content={image} />}

      {!noSocial && canonicalUrl && <link rel="canonical" href={canonicalUrl} />}

      {/* JSON-LD Structured Data */}
      {jsonLd && !noIndex && (
        <script type="application/ld+json">
          {JSON.stringify(jsonLd)}
        </script>
      )}
    </Helmet>
  )
}
