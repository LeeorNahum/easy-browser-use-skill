#!/usr/bin/env node
// Starts the chrome-devtools MCP server with its stdio passed straight through. On Windows it also makes sure the
// one watcher that answers Chrome's "Allow remote debugging?" window for every session is running. It never
// affects the server: if it cannot start, the server still runs and stderr says so.
import { spawn } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const serverArgs = process.argv.length > 2 ? process.argv.slice(2) : ['--autoConnect'];
const warn = message => console.error(`easy-browser-use: ${message}`);

// The server installed beside this package, whether npm nested it or hoisted it
function findServerEntry() {
  for (const dir of [join(here, '..', 'node_modules', 'chrome-devtools-mcp'), join(here, '..', '..', 'chrome-devtools-mcp')]) {
    const manifest = join(dir, 'package.json');
    if (!existsSync(manifest)) continue;
    const bin = JSON.parse(readFileSync(manifest, 'utf8')).bin;
    const rel = typeof bin === 'string' ? bin : bin?.['chrome-devtools-mcp'];
    if (rel && existsSync(resolve(dir, rel))) return resolve(dir, rel);
  }
}

const script = join(here, 'allow-remote-debugging.ps1');
const stateDir = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'easy-browser-use') : undefined;
const shell = ['pwsh.exe', 'powershell.exe'].find(name => (process.env.PATH ?? '').split(';').some(dir => dir && existsSync(join(dir, name))));
// The watcher script skips a Node process with this argument when it looks for launchers
const helperArg = '--watcher-helper';

// Node ends every process it started, and theirs, when it exits, unless it started them detached, and
// PowerShell started detached exits at once. So a detached copy of this script starts the watcher, passes
// on its READY, and stays until the watcher exits, which keeps the watcher out of every session's lifetime.
if (process.argv[2] === helperArg) {
  const watcher = spawn(shell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
    '-Watch', '-PidFile', join(stateDir, 'watcher.pid'), '-LogFile', join(stateDir, 'allow.log')],
    { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  watcher.stdout.on('data', chunk => { if (String(chunk).includes('READY')) process.stdout.write('READY\n', () => {}); });
  process.stdout.on('error', () => {});
  watcher.on('error', () => process.exit(1));
  watcher.on('exit', code => process.exit(code ?? 1));
  await new Promise(() => {});
}

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
      if (waitForReady) warn('the Allow window will not be answered automatically, because PowerShell or the script was not found');
      return done(false);
    }
    if (watcherRunning()) return done(true);
    let watcher;
    try {
      mkdirSync(stateDir, { recursive: true });
      appendFileSync(join(stateDir, 'allow.log'), '');
      // Detached, so the watcher outlives this launcher and goes on serving the other sessions
      watcher = spawn(process.execPath, [fileURLToPath(import.meta.url), helperArg],
        { detached: true, stdio: ['ignore', waitForReady ? 'pipe' : 'ignore', 'ignore'], windowsHide: true });
      watcher.unref();
    } catch (error) {
      if (waitForReady) warn(`the Allow window will not be answered automatically: ${error.message}`);
      return done(false);
    }
    if (!waitForReady) {
      watcher.on('error', () => {});
      return done(true);
    }
    let settled = false;
    const finish = ok => { if (settled) return; settled = true; clearTimeout(timer); watcher.stdout?.destroy(); done(ok); };
    watcher.stdout.on('data', chunk => { if (String(chunk).includes('READY')) finish(true); });
    watcher.on('error', error => { warn(`the Allow window will not be answered automatically: ${error.message}`); finish(false); });
    watcher.on('exit', () => { if (!settled) warn('the Allow window will not be answered automatically, because the watcher stopped while starting'); finish(false); });
    const timer = setTimeout(() => {
      warn('the Allow window watcher did not start in time, so the server starts without it');
      watcher.kill();
      finish(false);
    }, 15000);
  });
}

if (process.platform === 'win32') {
  await ensureWatcher(true);
  // A watcher that stopped, or that left just as this launcher found it, is replaced within seconds
  setInterval(() => { ensureWatcher(false); }, 5000).unref();
}

// Without an installed server, Node's own copy of npx fetches it, and no shell touches the server flags
const npxCli = join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npx-cli.js');
const entry = findServerEntry();
if (!entry && !existsSync(npxCli)) {
  warn('the chrome-devtools-mcp server is not installed beside the launcher and Node has no copy of npx to fetch it');
  process.exit(1);
}
const server = entry
  ? spawn(process.execPath, [entry, ...serverArgs], { stdio: 'inherit' })
  : spawn(process.execPath, [npxCli, '-y', 'chrome-devtools-mcp@latest', ...serverArgs], { stdio: 'inherit' });

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => server.kill(signal));
server.on('error', error => { warn(`could not start the server: ${error.message}`); process.exit(1); });
server.on('exit', (code, signal) => { process.exit(code ?? (signal ? 1 : 0)); });
