#!/usr/bin/env node
// Starts the chrome-devtools MCP server with its stdio passed straight through. On Windows it first
// starts the prompt script in watch mode and waits for it to be watching, so Chrome's "Allow remote debugging?" window is answered
// for chrome-devtools connections without the agent doing anything. The watcher never affects the
// server: if it cannot start or stops, the server still runs and the launcher says so on stderr.
import { spawn } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
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

// The watcher prints READY once it has taken note of the windows already open. Waiting for that
// keeps the server from raising a window the watcher would then take for an old one.
function startWatcher() {
  return new Promise(done => {
    const script = join(here, 'allow-remote-debugging.ps1');
    const appData = process.env.LOCALAPPDATA;
    const shell = ['pwsh.exe', 'powershell.exe'].find(name => (process.env.PATH ?? '').split(';').some(dir => dir && existsSync(join(dir, name))));
    if (!appData || !shell || !existsSync(script)) {
      warn('the Allow window will not be answered automatically, because PowerShell or the script was not found');
      return done(undefined);
    }
    let watcher;
    let timer;
    const finish = value => { clearTimeout(timer); done(value); };
    try {
      const logDir = join(appData, 'easy-browser-use');
      const logFile = join(logDir, 'allow.log');
      mkdirSync(logDir, { recursive: true });
      appendFileSync(logFile, '');
      watcher = spawn(shell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
        '-Watch', '-ParentPid', String(process.pid), '-LogFile', logFile], { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
    } catch (error) {
      warn(`the Allow window will not be answered automatically: ${error.message}`);
      return done(undefined);
    }
    let ready = false;
    watcher.stdout.on('data', chunk => { if (!ready && String(chunk).includes('READY')) { ready = true; finish(watcher); } });
    watcher.on('error', error => { warn(`the Allow window will not be answered automatically: ${error.message}`); finish(undefined); });
    watcher.on('exit', code => { if (!ready) { warn('the Allow window will not be answered automatically, because the watcher stopped while starting'); finish(undefined); } else if (!stopping) warn(`the Allow window watcher stopped with code ${code}, see allow.log`); });
    timer = setTimeout(() => {
      if (ready) return;
      warn('the Allow window watcher did not start in time, so the server starts without it');
      watcher.kill();
      finish(undefined);
    }, 15000);
  });
}

let stopping = false;
const watcher = process.platform === 'win32' ? await startWatcher() : undefined;

// Without an installed server, Node's own copy of npx fetches it, and no shell touches the server flags
const npxCli = join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npx-cli.js');
const entry = findServerEntry();
if (!entry && !existsSync(npxCli)) {
  warn('the chrome-devtools-mcp server is not installed beside the launcher and Node has no copy of npx to fetch it');
  watcher?.kill();
  process.exit(1);
}
const server = entry
  ? spawn(process.execPath, [entry, ...serverArgs], { stdio: 'inherit' })
  : spawn(process.execPath, [npxCli, '-y', 'chrome-devtools-mcp@latest', ...serverArgs], { stdio: 'inherit' });

function stop(signal) {
  stopping = true;
  watcher?.kill();
  server.kill(signal);
}
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => stop(signal));
server.on('error', error => { stopping = true; warn(`could not start the server: ${error.message}`); watcher?.kill(); process.exit(1); });
server.on('exit', (code, signal) => { stopping = true; watcher?.kill(); process.exit(code ?? (signal ? 1 : 0)); });
