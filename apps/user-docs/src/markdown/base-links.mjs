// Pages link to each other by root-relative routes (`/guides/package/`, `/zh/guides/package/`),
// which `zig build check-docs` resolves against src/content/docs. A versioned build is served
// under a base path (`/v0.2/`), so this Sätteri mdast plugin prefixes those links with the base.
// It runs before every hast plugin, so the links validator checks the prefixed links.

/**
 * @param {string} base Astro `base`, starting and ending with `/`.
 * @param {string} url Link target from Markdown.
 */
export function withBase(base, url) {
  if (!url.startsWith('/') || url.startsWith('//')) return url;
  if (base === '/') return url;
  return base + url.slice(1);
}

/** @param {string} base Astro `base`, starting and ending with `/`. */
export function baseLinks(base) {
  if (!base.startsWith('/') || !base.endsWith('/')) {
    throw new Error(`base must start and end with '/', got '${base}'`);
  }
  /** @param {{ url: string }} node @param {{ setProperty: Function }} ctx */
  const rewrite = (node, ctx) => {
    const url = withBase(base, node.url);
    if (url !== node.url) ctx.setProperty(node, 'url', url);
  };
  return { name: 'niobium-base-links', link: rewrite, definition: rewrite };
}
