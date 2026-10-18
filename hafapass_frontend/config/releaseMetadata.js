export function resolveRevision(env, gitRevision) {
  // Netlify's build identity takes precedence over manually supplied values.
  const candidate = env.COMMIT_REF || env.VITE_APP_REVISION || env.VITE_SENTRY_RELEASE || gitRevision
  return /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i.test(candidate || '') ? candidate.toLowerCase() : null
}

export function releaseMetadataPlugin(revision) {
  return {
    name: 'hafapass-release-metadata',
    generateBundle() {
      this.emitFile({ type: 'asset', fileName: 'release.json', source: JSON.stringify({ revision }) })
    },
  }
}
