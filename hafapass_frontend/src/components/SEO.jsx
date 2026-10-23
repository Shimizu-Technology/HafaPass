import { Helmet } from 'react-helmet-async'
import { PUBLIC_WEB_URL } from '../utils/site'

const SITE_NAME = 'HåfaPass'
const DEFAULT_TITLE = 'HåfaPass — Your Pass to Every Event on Guam'
const DEFAULT_DESCRIPTION = 'HåfaPass (HafaPass) — discover and book tickets for the best events on Guam. Nightlife, concerts, festivals, dining, sports, and more.'
const DEFAULT_IMAGE = `${PUBLIC_WEB_URL}/og-default.jpg`
const SITE_URL = PUBLIC_WEB_URL

export default function SEO({
  title,
  description = DEFAULT_DESCRIPTION,
  image = DEFAULT_IMAGE,
  url,
  type = 'website',
  jsonLd,
  noIndex = false,
  noSocial = false,
}) {
  const fullTitle = title ? `${title} | ${SITE_NAME}` : DEFAULT_TITLE
  const canonicalUrl = url || SITE_URL

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
      {!noSocial && <meta property="og:url" content={canonicalUrl} />}
      {!noSocial && <meta property="og:type" content={type} />}
      {!noSocial && <meta property="og:site_name" content={SITE_NAME} />}

      {/* Twitter Card */}
      {!noSocial && <meta name="twitter:card" content="summary_large_image" />}
      {!noSocial && <meta name="twitter:title" content={title || DEFAULT_TITLE} />}
      {!noSocial && <meta name="twitter:description" content={description} />}
      {!noSocial && <meta name="twitter:image" content={image} />}

      {!noSocial && <link rel="canonical" href={canonicalUrl} />}

      {/* JSON-LD Structured Data */}
      {jsonLd && !noIndex && (
        <script type="application/ld+json">
          {JSON.stringify(jsonLd)}
        </script>
      )}
    </Helmet>
  )
}
