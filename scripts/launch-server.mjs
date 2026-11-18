#!/usr/bin/env node
// Starts the chrome-devtools MCP server with its stdio passed straight through, sending Google no usage statistics
// or trace URLs, keeping one navigation's requests and messages, and letting file tools reach every local fixed
// drive. On Windows it also makes sure the one watcher that answers Chrome's "Allow remote debugging?" window for
// every session is running, and lets update.mjs install a newer release in the background for the next session.
// Neither affects the server: if one cannot start, the server still runs and stderr says so.
import { execFile, spawn } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { compare, installedCopies, isEntry, maybeUpdate, readCopy, stateDir, updatable, versionsDir } from './update.mjs';

const self = fileURLToPath(import.meta.url);
const here = dirname(self);
const pkgDir = join(here, '..');
const userArgs = process.argv.slice(2);
const warn = message => console.error(`easy-browser-use: ${message}`);

// The server's own config file: the one --config names, or else the first that the server finds by itself
function configFile() {
  for (const [i, arg] of userArgs.entries()) {
    const named = /^--config(?:=(.*))?$/.exec(arg);
    if (named) return resolve(named[1] ?? userArgs[i + 1] ?? '');
  }
  const { CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY: off, PLUGIN_DATA: plugin, LOCALAPPDATA: local, XDG_CONFIG_HOME: xdg } = process.env;
  if (off) return undefined;
  const shared = process.platform === 'win32'
    ? (local ? join(local, 'Google', 'cd4a', 'config.json') : undefined)
    : (xdg && isAbsolute(xdg) ? join(xdg, 'cd4a', 'config.json') : undefined);
  return [plugin && join(plugin, 'cd4a.config.json'), shared ?? join(homedir(), '.config', 'cd4a', 'config.json')]
    .find(file => { try { return file && statSync(file).isFile(); } catch { return false; } });
}

// The options the config file sets, keyed the way the checks below spell them, so its values win over the defaults
function configured() {
  const file = configFile();
  if (!file) return new Map();
  try {
    const options = JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
    return new Map(Object.entries(options).map(([key, value]) => [key.replaceAll('-', '').toLowerCase(), value]));
  } catch { return new Map(); }
}

// Whether unrestricted paths are on, read the way the server reads them: the last of the user's flags counts, and
// only true, given as =true, as the next argument, or by the bare flag, turns them on. With no such flag, the config
// file's value counts, where true or "true" turns them on.
function unrestrictedPaths(set) {
  let on;
  for (const [i, arg] of userArgs.entries()) {
    const flag = /^--(no-)?(allowUnrestrictedPaths|allow-unrestricted-paths)(?:=(.*))?$/.exec(arg);
    if (flag) on = !flag[1] && (flag[3] !== undefined ? flag[3] === 'true' : userArgs[i + 1] !== 'false');
  }
  return on ?? [true, 'true'].includes(set.get('allowunrestrictedpaths'));
}

// Every local fixed drive's root, written as C:\ because C: alone is the working folder on that drive. fsutil names
// each drive's type in a fraction of the time PowerShell takes to start.
async function fixedDrives() {
  const fsutil = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'fsutil.exe');
  const run = args => new Promise(done =>
    execFile(fsutil, args, { windowsHide: true, timeout: 3000 }, (error, stdout) => done(error ? undefined : stdout)));
  const listed = await run(['fsinfo', 'drives']);
  const roots = listed?.match(/\b[A-Z]:\\/g) ?? [];
  const types = await Promise.all(roots.map(root => run(['fsinfo', 'drivetype', root.slice(0, 2)])));
  const fixed = roots.filter((root, i) => /Fixed Drive/.test(types[i] ?? ''));
  if (!fixed.length) {
    // fsutil names each type in the language of Windows, and the launcher knows only the English words
    const why = listed === undefined || types.includes(undefined) ? 'fsutil failed'
      : types.every(type => /Drive|Ram Disk|Root Directory/.test(type)) ? 'no local fixed drive was found'
      : 'fsutil named the drive types in a language other than English';
    warn(`${why}, so file tools reach only the folders the harness and the server allow`);
  }
  return fixed;
}

// The server's arguments: the defaults first, so a flag the user passes after them wins, and then the user's own,
// or --autoConnect when the user passed none. A default is left out where the user set that option in the config
// file, since any command-line flag would override it there, and where the user passed a number of their own, since
// the server rejects a number given twice. The drive roots join any folders the user passes with --workspace.
async function serverArgs() {
  const set = configured();
  const passed = pattern => userArgs.some(arg => pattern.test(arg));
  const defaults = [];
  if (!set.has('usagestatistics')) defaults.push('--no-usage-statistics');
  if (!set.has('performancecrux')) defaults.push('--no-performance-crux');
  if (!set.has('maxnavigationsaved') && !passed(/^--(maxNavigationSaved|max-navigation-saved)(=|$)/)) defaults.push('--maxNavigationSaved=1');
  // The server refuses to start with unrestricted paths and --workspace both on, and any --workspace on the
  // command line would replace the folders the config file lists
  const pathsSet = unrestrictedPaths(set) || set.has('filesystemroot') || set.has('workspace');
  if (process.platform === 'win32' && !pathsSet) for (const root of await fixedDrives()) defaults.push(`--workspace=${root}`);
  return [...defaults, ...(userArgs.length ? userArgs : ['--autoConnect'])];
}

// A copy in the versions folder keeps its own file open for as long as it runs, which keeps update.mjs from removing it
if (versionsDir && self.toLowerCase().startsWith((versionsDir + sep).toLowerCase())) openSync(self, 'r');

const script = join(here, 'allow-remote-debugging.ps1');
const shell = ['pwsh.exe', 'powershell.exe'].find(name => (process.env.PATH ?? '').split(';').some(dir => dir && existsSync(join(dir, name))));
// The watcher script skips a Node process with this argument when it looks for launchers
const helperArg = '--watcher-helper';

// The watcher holds its pid file open for writing while it runs, so the file cannot be opened for writing
// here. A file left by a watcher that has stopped opens, whatever process now has its old number.
function watcherRunning() {
  try {
    closeSync(openSync(join(stateDir, 'watcher.pid'), 'r+'));
    return false;
  } catch (error) { return error.code === 'EBUSY'; }
}

// Starts the shared watcher when none is running. On the first start it waits for READY, which the watcher
// prints once it is watching, so the server's first window is answered.
function ensureWatcher(waitForReady) {
  return new Promise(done => {
    if (!stateDir || !shell || !existsSync(script)) {
      if (waitForReady) warn('the watcher will not start, because PowerShell or the script was not found');
      return done(false);
    }
    if (watcherRunning()) return done(true);
    let watcher;
    try {
      mkdirSync(stateDir, { recursive: true });
      appendFileSync(join(stateDir, 'allow.log'), '');
      // Detached, so the watcher outlives this launcher and goes on serving the other sessions
      watcher = spawn(process.execPath, [self, helperArg],
        { detached: true, stdio: ['ignore', waitForReady ? 'pipe' : 'ignore', 'ignore'], windowsHide: true });
      watcher.unref();
    } catch (error) {
      if (waitForReady) warn(`the watcher will not start: ${error.message}`);
      return done(false);
    }
    if (!waitForReady) {
      watcher.on('error', () => {});
      return done(true);
    }
    let settled = false;
    const finish = ok => { if (settled) return; settled = true; clearTimeout(timer); watcher.stdout?.destroy(); done(ok); };
    watcher.stdout.on('data', chunk => { if (String(chunk).includes('READY')) finish(true); });
    watcher.on('error', error => { warn(`the watcher will not start: ${error.message}`); finish(false); });
    watcher.on('exit', () => { if (!settled) warn('the watcher stopped while starting, so the server starts without it'); finish(false); });
    const timer = setTimeout(() => {
      warn('the watcher did not start in time, so the server starts without it');
      watcher.kill();
      finish(false);
    }, 15000);
  });
}

// Node ends every process it started, and theirs, when it exits, unless it started them detached, and
// PowerShell started detached exits at once. So a detached copy of this script starts the watcher, passes
// on its READY, and stays until the watcher exits, which keeps the watcher out of every session's lifetime.
async function runHelper() {
  const watcher = spawn(shell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
    '-Watch', '-PidFile', join(stateDir, 'watcher.pid'), '-LogFile', join(stateDir, 'allow.log')],
    { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  watcher.stdout.on('data', chunk => { if (String(chunk).includes('READY')) process.stdout.write('READY\n', () => {}); });
  process.stdout.on('error', () => {});
  watcher.on('error', () => process.exit(1));
  watcher.on('exit', code => process.exit(code ?? 1));
  await new Promise(() => {});
}

// Runs the session. A launcher installed earlier calls this on the newest copy it finds, so it keeps its name
// from one release to the next and rejects only before it starts the server.
export async function start() {
  maybeUpdate(warn);
  // The drives are listed while the watcher starts, and the server waits for both
  const args = serverArgs();
  if (process.platform === 'win32') {
    await ensureWatcher(true);
    // A watcher that stopped, or that left just as this launcher found it, is replaced within seconds
    setInterval(() => { ensureWatcher(false); }, 5000).unref();
  }

  // Without an installed server, Node's own copy of npx fetches it, and no shell touches the server flags
  const npxCli = join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npx-cli.js');
  const entry = readCopy(pkgDir)?.entry;
  if (!entry && !existsSync(npxCli)) {
    warn('the chrome-devtools-mcp server is not installed beside the launcher and Node has no copy of npx to fetch it');
    process.exit(1);
  }
  // The launcher keeps the server current itself, so the server's own check for a newer release is turned off
  const options = { stdio: 'inherit', env: { ...process.env, CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: '1' } };
  const server = entry
    ? spawn(process.execPath, [entry, ...await args], options)
    : spawn(process.execPath, [npxCli, '-y', 'chrome-devtools-mcp@latest', ...await args], options);

  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => server.kill(signal));
  server.on('error', error => { warn(`could not start the server: ${error.message}`); process.exit(1); });
  server.on('exit', (code, signal) => { process.exit(code ?? (signal ? 1 : 0)); });
}

// The newest complete copy runs the session. One that fails to load or to start is passed over for the next newest.
async function route() {
  if (updatable) {
    const mine = readCopy(pkgDir);
    for (const copy of installedCopies()) {
      if (compare(copy, mine) <= 0) break;
      try {
        return await (await import(pathToFileURL(copy.launcher).href)).start();
      } catch (error) {
        warn(`the copy ${copy.folder} did not start, so an older copy runs: ${error.message}`);
      }
    }
  }
  return start();
}

if (isEntry(import.meta.url)) await (process.argv[2] === helperArg ? runHelper() : route());
