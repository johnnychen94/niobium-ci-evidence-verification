// Client side of the version switcher and banners. /versions.json is written by
// scripts/build-versions.mjs at the site root, next to the version directories.

export interface VersionEntry {
  /** `next` or a release line `vX.Y`. */
  id: string;
  /** Site path of the version, e.g. `/v0.2/`. */
  path: string;
  released: boolean;
}

export interface VersionList {
  /** Release line served at `/latest/`, or null before the first release. */
  latest: string | null;
  versions: VersionEntry[];
}

/** Same bound as scripts/build-versions.mjs, plus `next`. */
const maxVersions = 13;
const idPattern = /^(next|v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$/;
const pathPattern = /^\/[a-z0-9][a-z0-9.-]*\/$/;

function isEntry(value: unknown): value is VersionEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return (
    typeof entry.id === 'string' &&
    idPattern.test(entry.id) &&
    typeof entry.path === 'string' &&
    pathPattern.test(entry.path) &&
    typeof entry.released === 'boolean'
  );
}

/** The published version list, or null when it is missing or malformed (e.g. `npm run dev`). */
export async function loadVersions(): Promise<VersionList | null> {
  try {
    const response = await fetch('/versions.json', { cache: 'no-cache' });
    if (!response.ok) return null;
    const data: unknown = await response.json();
    if (typeof data !== 'object' || data === null) return null;
    const { latest, versions } = data as Record<string, unknown>;
    if (latest !== null && (typeof latest !== 'string' || !idPattern.test(latest))) return null;
    if (!Array.isArray(versions) || versions.length > maxVersions) return null;
    if (!versions.every(isEntry)) return null;
    return { latest, versions };
  } catch {
    return null;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    const response = await fetch(path, { method: 'HEAD' });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Where switching to version `id` goes: the same page and locale in that version when it
 * exists, else that version's home in the same locale, else that version's home.
 */
export async function switchTarget(
  list: VersionList,
  id: string,
  base: string,
  location: Location,
): Promise<string | null> {
  const entry = list.versions.find((candidate) => candidate.id === id);
  if (!entry) return null;
  const root = entry.id === list.latest ? '/latest/' : entry.path;
  const rest = location.pathname.startsWith(base) ? location.pathname.slice(base.length) : '';
  const locale = rest === 'zh/' || rest.startsWith('zh/') ? 'zh/' : '';
  const candidates = [root + rest, root + locale];
  for (const candidate of candidates) {
    if (await exists(candidate)) return candidate === root + rest ? candidate + location.hash : candidate;
  }
  return root;
}
