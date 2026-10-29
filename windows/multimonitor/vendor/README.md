# Local Zebar client

`zebar.js` bundles Zebar 3.0.0 and its runtime dependencies for offline startup.
The bar does not load Babel, React, or remote JavaScript. Weather still uses its provider's network requests.

To rebuild, from this directory run `npm ci --ignore-scripts` then `node build.mjs`.
The committed lockfile pins the complete build graph. Node/npm are not needed to install or run the desktop.
See LICENSES.txt for dependency licences and source archive locations. Zebar and glazewm are GPL-3.0-only.

Upstream source: https://github.com/glzr-io/zebar/tree/v3.0.0 and
https://github.com/glzr-io/glazewm/tree/main/packages/client-api (the npm source
archive for glazewm 1.7.0 also includes its TypeScript sources).

The pinned upstream Zebar release depends on Zod 3.24.2. npm audit reports
GHSA-mrhx-c7xc-m3w5 for that dependency; no compatible upstream fix is available.
Do not force a Zod 4 override across this API boundary. Review the advisory when
upgrading Zebar; this bundle is used with the repository's local widget config.
