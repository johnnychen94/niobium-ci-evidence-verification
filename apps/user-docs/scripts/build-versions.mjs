// Builds every published documentation version into dist-versions/, the GitHub Pages artifact
// (docs/adr/0015-node-toolchain-for-user-docs.md). actions/deploy-pages replaces the whole
// site, so each deploy rebuilds all versions:
//
//   /next/        the `next` ref (default: this working tree; CI passes --next-ref origin/main)
//   /vX.Y/        the highest vX.Y.Z tag of each release line whose tree has apps/user-docs
//   /latest/      the newest release line again, built with base /latest/
//   /             CNAME, versions.json, llms*.txt and redirects to /latest/ (or /next/)
//
// Each tag is built in a temporary git worktree with its own lockfile and config. A tag that
// fails to build or ignores DOCS_BASE fails the whole run; nothing is dropped silently.
//
// Usage: npm run build:versions [-- --next-ref <git ref>]

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Release lines published at most; older lines are listed in the log and not built. */
const maxReleaseLines = 12;
/** Release tags: plain semantic versions, no pre-release or build suffix. */
const tagPattern = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const siteRelative = 'apps/user-docs';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(siteDir, 'dist-versions');

function run(command, args, options = {}) {
  return execFileSync(command, args, { encoding: 'utf8', stdio: 'pipe', ...options });
}

function git(args, cwd = siteDir) {
  return run('git', args, { cwd }).trim();
}

function parseArgs(argv) {
  const args = { nextRef: null };
  if (argv.length === 0) return args;
  if (argv.length === 2 && argv[0] === '--next-ref' && argv[1]) {
    args.nextRef = argv[1];
    return args;
  }
  throw new Error('usage: build-versions.mjs [--next-ref <git ref>]');
}

/** The highest patch tag of each release line that has the site, newest line first. */
export function releaseLines(tags, hasSite) {
  const byLine = new Map();
  for (const tag of tags) {
    const match = tagPattern.exec(tag);
    if (!match) continue;
    const [major, minor, patch] = match.slice(1).map(Number);
    const id = `v${major}.${minor}`;
    const best = byLine.get(id);
    if (best && best.patch >= patch) continue;
    if (!hasSite(tag)) continue;
    byLine.set(id, { id, tag, major, minor, patch });
  }
  return [...byLine.values()].sort((a, b) => b.major - a.major || b.minor - a.minor);
}

function hasSite(tag) {
  try {
    git(['cat-file', '-e', `${tag}:${siteRelative}/package.json`]);
    return true;
  } catch {
    return false;
  }
}

/** Builds the site in `dir` for one version and copies it to dist-versions/<name>/. */
function buildInto(dir, version, base, name) {
  console.log(`\n== ${name}: version ${version}, base ${base}, from ${relative(siteDir, dir) || '.'}`);
  const env = { ...process.env, DOCS_VERSION: version, DOCS_BASE: base, ASTRO_TELEMETRY_DISABLED: '1' };
  rmSync(join(dir, 'dist'), { recursive: true, force: true });
  run('npm', ['run', 'build'], { cwd: dir, env, stdio: 'inherit' });
  const index = join(dir, 'dist', 'index.html');
  if (!existsSync(index) || !readFileSync(index, 'utf8').includes(`href="${base}`)) {
    throw new Error(`${name}: the build does not serve its pages under ${base} (DOCS_BASE ignored?)`);
  }
  cpSync(join(dir, 'dist'), join(outDir, name), { recursive: true });
}

/** Checks out `ref` into a temporary worktree, installs its locked dependencies, returns the site dir. */
function checkout(ref, scratch, name, worktrees) {
  const path = join(scratch, name);
  git(['worktree', 'add', '--detach', path, ref]);
  worktrees.push(path);
  const dir = join(path, siteRelative);
  run('npm', ['ci', '--no-audit', '--no-fund'], { cwd: dir, stdio: 'inherit' });
  return dir;
}

function redirectPage(target, lang) {
  return `<!doctype html>
<html lang="${lang}">
<head>
<meta charset="utf-8">
<title>Niobium documentation</title>
<meta http-equiv="refresh" content="0; url=${target}">
<link rel="canonical" href="${target}">
<meta name="robots" content="noindex">
</head>
<body><p><a href="${target}">${target}</a></p></body>
</html>
`;
}

/**
 * Root 404: GitHub Pages serves /404.html for every missing path. A path outside any version
 * (an old unversioned link such as /guides/package/) is sent to the same path in the default
 * version; a missing page inside a version shows that version's 404 page.
 */
function rootNotFound(defaultName, names) {
  const page = readFileSync(join(outDir, defaultName, '404.html'), 'utf8');
  const script = `<script>(function(){var v=${JSON.stringify(names)};` +
    `var p=location.pathname.split('/')[1];if(v.indexOf(p)<0){location.replace(` +
    `${JSON.stringify(`/${defaultName}`)}+location.pathname+location.search+location.hash);}})();</script>`;
  if (!page.includes('<head>')) throw new Error(`${defaultName}/404.html has no <head>`);
  return page.replace('<head>', `<head>${script}`);
}

function assembleRoot(lines) {
  const defaultName = lines.length > 0 ? 'latest' : 'next';
  const versions = [
    { id: 'next', path: '/next/', released: false },
    ...lines.map((line) => ({ id: line.id, path: `/${line.id}/`, released: true, tag: line.tag })),
  ];
  const list = { latest: lines.length > 0 ? lines[0].id : null, versions };
  writeFileSync(join(outDir, 'versions.json'), `${JSON.stringify(list, null, 2)}\n`);
  cpSync(join(siteDir, 'public', 'CNAME'), join(outDir, 'CNAME'));
  writeFileSync(join(outDir, 'index.html'), redirectPage(`/${defaultName}/`, 'en'));
  mkdirSync(join(outDir, 'zh'), { recursive: true });
  writeFileSync(join(outDir, 'zh', 'index.html'), redirectPage(`/${defaultName}/zh/`, 'zh-CN'));
  for (const file of ['llms.txt', 'llms-full.txt', 'llms-small.txt']) {
    cpSync(join(outDir, defaultName, file), join(outDir, file));
  }
  const names = ['next', 'latest', ...lines.map((line) => line.id)];
  writeFileSync(join(outDir, '404.html'), rootNotFound(defaultName, names));
  return list;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const tags = git(['tag', '--list', 'v*']).split('\n').filter(Boolean);
  const all = releaseLines(tags, hasSite);
  const lines = all.slice(0, maxReleaseLines);
  for (const line of all.slice(maxReleaseLines)) {
    console.log(`not published (over ${maxReleaseLines} release lines): ${line.tag}`);
  }
  console.log(`release lines: ${lines.map((line) => line.tag).join(', ') || 'none, next only'}`);

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const scratch = mkdtempSync(join(tmpdir(), 'niobium-docs-'));
  const worktrees = [];
  try {
    const nextDir = args.nextRef ? checkout(args.nextRef, scratch, 'next', worktrees) : siteDir;
    buildInto(nextDir, 'next', '/next/', 'next');
    for (const [index, line] of lines.entries()) {
      const dir = checkout(line.tag, scratch, line.id, worktrees);
      buildInto(dir, line.id, `/${line.id}/`, line.id);
      if (index === 0) buildInto(dir, 'latest', '/latest/', 'latest');
    }
    const list = assembleRoot(lines);
    console.log(`\nassembled ${relative(siteDir, outDir)}: latest ${list.latest ?? 'none'}`);
  } finally {
    for (const path of worktrees) git(['worktree', 'remove', '--force', path]);
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`build-versions: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}
