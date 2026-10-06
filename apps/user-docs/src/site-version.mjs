// Which documentation version this build is, set by scripts/build-versions.mjs:
// DOCS_VERSION is `next`, `latest` or a release line `vX.Y`; DOCS_BASE is the path it is served
// under (`/next/`, `/latest/`, `/v0.2/`). A plain `npm run build` is `next` served at `/`.

const versionPattern = /^(next|latest|v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$/;
const basePattern = /^\/([a-z0-9][a-z0-9.-]*\/)?$/;

export const docsVersion = process.env.DOCS_VERSION || 'next';
export const docsBase = process.env.DOCS_BASE || '/';

if (!versionPattern.test(docsVersion)) {
  throw new Error(`DOCS_VERSION must be next, latest or vX.Y, got '${docsVersion}'`);
}
if (!basePattern.test(docsBase)) {
  throw new Error(`DOCS_BASE must be '/' or '/<name>/', got '${docsBase}'`);
}

/** Whether this build is a release line (`vX.Y`), which may be older than the latest release. */
export const isReleaseLine = docsVersion.startsWith('v');
