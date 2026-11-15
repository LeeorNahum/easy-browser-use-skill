#!/usr/bin/env node
// Keeps an installed launcher current, and holds the helpers the launcher uses to find the copies on disk. Each
// release goes into a folder of its own under versions in the install folder, and a session starts the newest
// complete copy, so a running session keeps the files it started with and an install that fails partway leaves
// every other copy as it was. The launcher calls maybeUpdate as a session starts, and when a check is due this
// script runs detached, outside every session's lifetime.
import { spawn } from 'node:child_process';
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), '..');
// The shared watcher's folder, one per signed-in Windows user
export const stateDir = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'easy-browser-use') : undefined;

const readJson = file => { try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return undefined; } };

// Whether the module at this URL is the script Node was started with
export function isEntry(url) {
  try { return realpathSync(process.argv[1]).toLowerCase() === fileURLToPath(url).toLowerCase(); } catch { return false; }
}

// The copy in a package folder: its launcher, the server installed beside it, whether npm nested it or hoisted
// it, and the package spec npm saved when it installed the copy into a folder of its own
export function readCopy(dir) {
  const version = readJson(join(dir, 'package.json'))?.version;
  const launcher = join(dir, 'scripts', 'launch-server.mjs');
  if (!version || !existsSync(launcher)) return undefined;
  const folder = basename(resolve(dir, '..', '..'));
  const spec = basename(resolve(dir, '..')).toLowerCase() === 'node_modules'
    ? readJson(join(dir, '..', '..', 'package.json'))?.dependencies?.['easy-browser-use'] : undefined;
  for (const serverDir of [join(dir, 'node_modules', 'chrome-devtools-mcp'), join(dir, '..', 'chrome-devtools-mcp')]) {
    const manifest = readJson(join(serverDir, 'package.json'));
    const bin = manifest?.bin;
    const rel = typeof bin === 'string' ? bin : bin?.['chrome-devtools-mcp'];
    if (rel && existsSync(resolve(serverDir, rel))) return { dir, folder, spec, launcher, version, server: manifest.version, entry: resolve(serverDir, rel) };
  }
  return { dir, folder, spec, launcher, version };
}

const parts = version => (/^(\d+)\.(\d+)\.(\d+)$/.exec(version ?? '')?.slice(1) ?? [0, 0, 0]).map(Number);
const compareVersions = (a, b) => { const [x, y] = [parts(a), parts(b)]; return x[0] - y[0] || x[1] - y[1] || x[2] - y[2]; };
// Orders copies by the launcher's version, then the server's
export const compare = (a, b) => compareVersions(a.version, b.version) || compareVersions(a.server, b.server);

// The install folder is the folder npm installed the hand-installed copy into, and it holds every later copy
// under versions. When installed as the setup says, it is also the watcher's folder.
const prefix = resolve(pkgDir, '..', '..');
const aboveVersions = dirname(dirname(prefix));
const handInstalled = basename(dirname(prefix)).toLowerCase() === 'versions'
  ? readCopy(join(aboveVersions, 'node_modules', 'easy-browser-use')) : undefined;
const installDir = handInstalled ? aboveVersions : prefix;

// What this copy updates from: nothing for a checkout, off Windows, or for a copy whose spec is no longer the
// hand-installed copy's
const ownSpec = readCopy(pkgDir)?.spec;
const spec = process.platform === 'win32' && (!handInstalled || handInstalled.spec === ownSpec) ? ownSpec : undefined;
export const updatable = Boolean(spec);
export const versionsDir = updatable ? join(installDir, 'versions') : undefined;
const stateFile = join(installDir, 'update.json');
const lockDir = join(installDir, 'update.lock');

// Every complete copy in the versions folder installed from the same spec as this one, newest first. Names
// starting with a dot are unfinished or being removed.
export function installedCopies() {
  let names;
  try { names = readdirSync(versionsDir); } catch { return []; }
  return names.filter(name => !name.startsWith('.'))
    .map(name => readCopy(join(versionsDir, name, 'node_modules', 'easy-browser-use')))
    .filter(copy => copy?.entry && copy.spec === spec)
    .sort((a, b) => compare(b, a));
}

// The lock is a folder holding a file named for the check it belongs to, which that check keeps open while it
// runs. Windows refuses to rename a folder with an open file in it, so a lock is taken over only when no check
// holds it and it is over a minute old, the minute covering a check that is still starting. Returns the name.
function claim() {
  const take = () => {
    mkdirSync(lockDir);
    const name = `${process.pid}-${Date.now()}`;
    writeFileSync(join(lockDir, name), '');
    return name;
  };
  try { return take(); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  const stale = `${lockDir}.${process.pid}`;
  try {
    if (Date.now() - statSync(lockDir).mtimeMs < MINUTE) return undefined;
    renameSync(lockDir, stale);
    // Another launcher may have taken the lock over between the look and the rename, so give back one that is new
    if (Date.now() - statSync(stale).mtimeMs < MINUTE) {
      try { renameSync(stale, lockDir); } catch { rmSync(stale, { recursive: true, force: true }); }
      return undefined;
    }
    rmSync(stale, { recursive: true, force: true });
    return take();
  } catch { return undefined; }
}

// Whether a check is due: a day after the last one, or an hour after one that failed, or at once for a spec
// that has not been checked here
function due(state) {
  const since = Date.now() - Date.parse(state?.checked);
  return state?.spec !== spec || !(since >= 0 && since < (state.error ? HOUR : 24 * HOUR));
}

// Starts a check in the background when one is due
export function maybeUpdate(warn) {
  if (!updatable) return;
  const state = readJson(stateFile);
  if (state?.error && state.spec === spec) warn(`could not update: ${state.error} (checked at ${state.checked}). The copy in use keeps running.`);
  if (!due(state)) return;
  try {
    const name = claim();
    if (!name) return;
    // A check that finished between the first look and the lock has already done the work
    if (!due(readJson(stateFile))) { rmSync(lockDir, { recursive: true, force: true }); return; }
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), name], { cwd: installDir, detached: true, stdio: 'ignore', windowsHide: true });
    child.on('error', error => { rmSync(lockDir, { recursive: true, force: true }); warn(`could not check for an update: ${error.message}`); });
    child.unref();
  } catch (error) {
    warn(`could not check for an update: ${error.message}`);
  }
}

// Runs a program hidden and without prompts, and resolves with its exit code and output
function run(file, args, timeout) {
  return new Promise(done => {
    const child = spawn(file, args, {
      cwd: installDir, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, timeout,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never' }
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => done({ code: -1, stdout, stderr, error }));
    child.on('close', code => done({ code, stdout, stderr }));
  });
}

// Why a run that did not exit with 0 failed
function failure({ code, stdout, error }) {
  if (error) return `could not start: ${error.message}`;
  if (code === null) return 'took too long';
  // Windows reports a process ended from outside with an exit code of all ones
  if (code > 0x7fffffff) return 'was stopped before it finished';
  let summary;
  try { summary = JSON.parse(stdout).error.summary; } catch { }
  return summary ? `failed: ${summary}` : `failed with exit code ${code}`;
}

const npmCli = join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js');
async function npm(label, args, timeout) {
  const result = await run(process.execPath, [npmCli, ...args, '--json', '--no-audit', '--no-fund', '--no-update-notifier', '--loglevel=error'], timeout);
  if (result.code !== 0) throw new Error(`npm ${label} ${failure(result)}`);
  return result.stdout;
}
const npmView = async (what, ...fields) => JSON.parse(await npm(`view ${what}`, ['view', what, ...fields], 2 * 60 * 1000));

// Removes copies that are older than the newest and that no session holds, and what an unfinished or interrupted
// check left over an hour ago. Every launcher running from the versions folder holds its own file open, and
// Windows refuses to rename a folder with an open file in it, so a copy in use fails the rename and stays.
function prune(keep) {
  for (const name of readdirSync(versionsDir).filter(name => name.startsWith('.'))) {
    const path = join(versionsDir, name);
    try { if (Date.now() - statSync(path).mtimeMs > HOUR) rmSync(path, { recursive: true, force: true }); } catch { }
  }
  for (const copy of installedCopies().filter(copy => !keep.includes(copy.dir.toLowerCase()))) {
    const folder = resolve(copy.dir, '..', '..');
    const trash = join(versionsDir, `.trash-${copy.folder}`);
    try { renameSync(folder, trash); } catch { continue; }
    try { rmSync(trash, { recursive: true, force: true }); } catch { }
  }
}

// Whether a new copy starts a session: its launcher loads and exports start, and its server runs
async function usable(copy) {
  const load = await run(process.execPath, ['--input-type=module', '-e',
    'const copy = await import(process.argv[1]); if (typeof copy.start !== "function") process.exit(2);',
    pathToFileURL(copy.launcher).href], 60 * 1000);
  if (load.code === 2) throw new Error(`the launcher of ${copy.version} has no start`);
  if (load.code !== 0) {
    const reason = load.stderr.split(/\r?\n/).find(line => /^\w*Error\b/.test(line));
    throw new Error(`the launcher of ${copy.version} does not load${reason ? `: ${reason}` : ''}`);
  }
  const server = await run(process.execPath, [copy.entry, '--version'], 60 * 1000);
  if (server.code !== 0) throw new Error(`the server ${copy.server} does not start`);
}

async function update() {
  if (!existsSync(npmCli)) throw new Error('Node has no copy of npm to install with');
  const mine = readCopy(pkgDir);
  const newest = [mine, ...installedCopies()].sort((a, b) => compare(b, a))[0];
  mkdirSync(versionsDir, { recursive: true });
  prune([mine.dir, newest.dir].map(dir => dir.toLowerCase()));

  // What a fresh install would get: the newest launcher the spec resolves to, and the newest server its range allows
  const remote = await npmView(spec, 'version', 'dependencies');
  const range = remote.dependencies?.['chrome-devtools-mcp'];
  const servers = range ? [await npmView(`chrome-devtools-mcp@${range}`, 'version')].flat() : [];
  const wanted = { version: remote.version, server: servers.sort(compareVersions).at(-1) };
  if (compare(wanted, newest) <= 0) return;

  const partial = join(versionsDir, `.partial-${process.pid}-${Date.now()}`);
  try {
    await npm(`install ${spec}`, ['install', '--prefix', partial, spec], 10 * 60 * 1000);
    const copy = readCopy(join(partial, 'node_modules', 'easy-browser-use'));
    if (!copy?.entry) throw new Error(`the copy npm installed from ${spec} has no launcher or no server`);
    if (compare(copy, newest) <= 0) return;
    await usable(copy);
    // A copy of the same versions from another spec keeps its folder, and this one takes the next free name
    let name = `${copy.version}+${copy.server}`;
    for (let n = 2; existsSync(join(versionsDir, name)); n++) {
      if (readCopy(join(versionsDir, name, 'node_modules', 'easy-browser-use'))?.spec === spec) return;
      name = `${copy.version}+${copy.server}-${n}`;
    }
    renameSync(partial, join(versionsDir, name));
  } finally {
    rmSync(partial, { recursive: true, force: true });
  }
}

if (isEntry(import.meta.url)) {
  // Held until the lock is removed, so no launcher can take the lock over while this check runs. When the file
  // is gone, another launcher took the lock over before this check started, and that check runs instead.
  let held;
  try { held = openSync(join(lockDir, process.argv[2] ?? ''), 'r+'); } catch { process.exit(0); }
  // A copy that no longer updates leaves the lock to one that does
  if (!updatable) { rmSync(lockDir, { recursive: true, force: true }); closeSync(held); process.exit(0); }
  let error;
  try { await update(); } catch (failure) { error = failure.message; }
  try { writeFileSync(stateFile, `${JSON.stringify({ spec, checked: new Date().toISOString(), ...(error && { error }) })}\n`); } catch { }
  try { rmSync(lockDir, { recursive: true, force: true }); } catch { }
  closeSync(held);
}
