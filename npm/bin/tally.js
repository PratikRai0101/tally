#!/usr/bin/env node
// Installs, updates and removes Tally.app, and prints usage from the terminal.
// No dependencies: Node's fetch, plus macOS's own ditto, codesign, plutil and open.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");

const RELEASE = require("../release.json");
const PKG = require("../package.json");
const BUNDLE_ID = "local.tally.menubar";

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith("-")));
const cmd = args.find((a) => !a.startsWith("-")) || "install";

const say = (s = "") => process.stdout.write(s + "\n");
class Fail extends Error {}
const fail = (s) => { throw new Fail(s); }; // thrown, so cleanup in finally blocks still runs
const run = (bin, argv, opts = {}) => execFileSync(bin, argv, { stdio: ["ignore", "pipe", "pipe"], ...opts }).toString().trim();
const tryRun = (bin, argv) => { try { return run(bin, argv); } catch { return null; } };

// ---------- where Tally lives ----------

function appPath() {
  if (process.env.TALLY_INSTALL_DIR) return path.join(path.resolve(process.env.TALLY_INSTALL_DIR), "Tally.app");
  const system = "/Applications/Tally.app";
  if (fs.existsSync(system) && bundleId(system) === BUNDLE_ID) return system;
  return path.join(os.homedir(), "Applications", "Tally.app");
}

const plist = (app, key) => tryRun("/usr/bin/plutil", ["-extract", key, "raw", path.join(app, "Contents", "Info.plist")]);
const bundleId = (app) => plist(app, "CFBundleIdentifier");
const appVersion = (app) => plist(app, "CFBundleShortVersionString");

// ---------- checks ----------

function checkMac() {
  if (process.platform !== "darwin") fail("Tally is a macOS app; this machine is " + process.platform + ".");
  const darwin = parseInt(os.release().split(".")[0], 10);
  if (darwin < 23) fail("Tally needs macOS 14 (Sonoma) or later.");
}

// Never overwrite some other app that happens to be called Tally.
function checkOwnership(app) {
  if (!fs.existsSync(app)) return;
  const id = bundleId(app);
  if (id !== BUNDLE_ID && !flags.has("--force")) {
    fail(`${app} is a different app (${id || "unknown bundle id"}). Move it away, or pass --force to replace it.`);
  }
}

// ---------- running copies ----------

function runningPids(app) {
  const out = tryRun("/usr/bin/pgrep", ["-x", "Tally"]);
  if (!out) return [];
  const exe = path.join(app, "Contents", "MacOS", "Tally");
  return out.split("\n").map(Number).filter((pid) => tryRun("/bin/ps", ["-o", "comm=", "-p", String(pid)]) === exe);
}

function quit(app) {
  const pids = runningPids(app);
  if (!pids.length) return false;
  for (const pid of pids) { try { process.kill(pid, "SIGTERM"); } catch {} }
  const until = Date.now() + 3000;
  while (Date.now() < until && runningPids(app).length) spawnSync("/bin/sleep", ["0.1"]);
  for (const pid of runningPids(app)) { try { process.kill(pid, "SIGKILL"); } catch {} }
  return true;
}

// ---------- commands ----------

async function install() {
  checkMac();
  const app = appPath();
  checkOwnership(app);

  const have = fs.existsSync(app) ? appVersion(app) : null;
  if (have === RELEASE.version && !flags.has("--force")) {
    say(`Tally ${have} is already installed at ${app}.`);
    say(`For a newer version: npx tally-menubar@latest update`);
    if (!flags.has("--no-open")) run("/usr/bin/open", [app]);
    return;
  }

  say(have ? `Updating Tally ${have} → ${RELEASE.version}` : `Installing Tally ${RELEASE.version}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tally-"));
  try {
    // 1. download
    const res = await fetch(RELEASE.url, { signal: AbortSignal.timeout(120000) });
    if (!res.ok) fail(`download failed: HTTP ${res.status} from ${RELEASE.url}`);
    const buf = Buffer.from(await res.arrayBuffer());
    say(`  downloaded ${(buf.length / 1e6).toFixed(1)} MB`);

    // 2. verify against the checksum shipped inside this package
    const sum = crypto.createHash("sha256").update(buf).digest("hex");
    if (sum !== RELEASE.sha256) fail(`checksum mismatch, refusing to install.\n  expected ${RELEASE.sha256}\n  got      ${sum}`);
    say("  checksum ok");

    // 3. unpack and sanity-check the bundle
    const zip = path.join(tmp, "Tally.zip");
    fs.writeFileSync(zip, buf);
    run("/usr/bin/ditto", ["-x", "-k", zip, path.join(tmp, "out")]);
    const fresh = path.join(tmp, "out", "Tally.app");
    if (!fs.existsSync(fresh) || bundleId(fresh) !== BUNDLE_ID) fail("the download did not contain Tally.app.");
    try { run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh]); } catch { fail("Tally.app failed its code-signature integrity check."); }

    // 4. swap it in: copy beside the target, then two renames
    fs.mkdirSync(path.dirname(app), { recursive: true });
    const staged = app + ".new", old = app + ".old";
    fs.rmSync(staged, { recursive: true, force: true });
    fs.rmSync(old, { recursive: true, force: true });
    run("/usr/bin/ditto", [fresh, staged]);
    const wasRunning = quit(app);
    if (fs.existsSync(app)) fs.renameSync(app, old);
    fs.renameSync(staged, app);
    fs.rmSync(old, { recursive: true, force: true });
    tryRun("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app]); // normally absent: Node downloads aren't quarantined
    say(`  installed ${app}`);

    if (!flags.has("--no-open")) {
      run("/usr/bin/open", [app]);
      say(wasRunning ? "  restarted Tally" : "  opened Tally: look for it in the menu bar");
    }
    if (have) say("\nmacOS may ask once more to let Tally read your Claude login from the Keychain; choose Always Allow.");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function usage() {
  checkMac();
  const app = appPath();
  if (!fs.existsSync(app)) fail("Tally isn't installed. Run: npx tally-menubar");
  const r = spawnSync(path.join(app, "Contents", "MacOS", "Tally"), ["--dump"], { stdio: "inherit" });
  process.exit(r.status ?? 1);
}

function uninstall() {
  checkMac();
  const app = appPath();
  if (!fs.existsSync(app)) { say("Tally isn't installed."); return; }
  checkOwnership(app);
  quit(app);
  fs.rmSync(app, { recursive: true, force: true });
  say(`Removed ${app}`);
  if (flags.has("--purge")) {
    tryRun("/usr/bin/defaults", ["delete", BUNDLE_ID]);
    say("Removed Tally's settings");
  } else {
    say("Settings were kept; add --purge to remove them too.");
  }
}

async function wrapped() {
  const opts = { "no-open": flags.has("--no-open") };
  const p = args.find((a) => a.startsWith("--period="));
  if (p) opts.period = p.split("=")[1];
  await require("../lib/wrapped.js").wrapped({ say, flags: opts, version: PKG.version });
}

function help() {
  say(`tally-menubar ${PKG.version}: installs Tally ${RELEASE.version}, AI plan limits in your macOS menu bar

  npx tally-menubar wrapped      your AI coding Wrapped: share cards from your logs (any OS)
  npx tally-menubar              install Tally and open it
  npx tally-menubar@latest update   update to the newest version
  npx tally-menubar usage        print spend, tokens and limits in the terminal
  npx tally-menubar uninstall    remove Tally (--purge also removes its settings)
  npx tally-menubar version      show versions

  Options: --no-open (don't launch or open the browser), --force (reinstall),
           --period=24h|7d|30d (which range the Wrapped opens on; default 30d)
  Installs to ~/Applications, or /Applications if Tally is already there.
  https://github.com/PratikRai0101/tally`);
}

function version() {
  const app = appPath();
  say(`tally-menubar ${PKG.version} (installs Tally ${RELEASE.version})`);
  say(fs.existsSync(app) ? `installed: Tally ${appVersion(app)} at ${app}` : "installed: none");
}

const commands = { install, update: install, usage, uninstall, version, help, wrapped };
if (flags.has("--help") || flags.has("-h")) help();
else if (flags.has("--version") || flags.has("-v")) version();
else if (!commands[cmd]) { help(); process.exit(1); }
else (async () => commands[cmd]())().catch((e) => {
  process.stderr.write("tally-menubar: " + e.message + "\n");
  process.exit(1);
});
