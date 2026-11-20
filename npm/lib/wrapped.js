// `npx tally-menubar wrapped`: reads the session logs your coding agents already keep, prices them,
// and opens a Wrapped-style deck in the browser. Runs on macOS, Linux and Windows. Nothing is uploaded;
// the only network call is LiteLLM's public price table (cached for a week).
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const HOME = os.homedir();
const DAY = 86400000;
const PERIODS = { "24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400 };

// ---------- prices (LiteLLM's table, same resolution rules as the app) ----------

const LITELLM = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

function cacheDir() {
  const d = process.platform === "darwin" ? path.join(HOME, "Library", "Caches", "tally-menubar")
    : process.platform === "win32" ? path.join(process.env.LOCALAPPDATA || path.join(HOME, "AppData", "Local"), "tally-menubar")
    : path.join(process.env.XDG_CACHE_HOME || path.join(HOME, ".cache"), "tally-menubar");
  try { fs.mkdirSync(d, { recursive: true }); } catch {}
  return d;
}

function ingest(text) {
  let obj;
  try { obj = JSON.parse(text); } catch { return null; }
  const doc = obj && (obj.document || obj);
  const t = new Map();
  for (const [k, v] of Object.entries(doc || {})) {
    if (!v || typeof v.input_cost_per_token !== "number" || typeof v.output_cost_per_token !== "number") continue;
    const inp = v.input_cost_per_token, write = v.cache_creation_input_token_cost ?? inp * 1.25;
    t.set(k.toLowerCase(), {
      input: inp, output: v.output_cost_per_token,
      cacheRead: v.cache_read_input_token_cost ?? inp * 0.1,
      cacheWrite: write, cacheWrite1h: v.cache_creation_input_token_cost_above_1hr ?? write * 1.6,
    });
  }
  return t.size ? t : null;
}

const readText = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };

async function loadPrices() {
  const own = path.join(cacheDir(), "model-prices.json");
  const app = path.join(HOME, "Library", "Application Support", "Tally", "model-prices.json");
  const fresh = (p) => { try { return Date.now() - fs.statSync(p).mtimeMs < 7 * DAY; } catch { return false; } };
  for (const p of [own, app]) if (fresh(p)) { const t = ingest(readText(p)); if (t) return t; }
  try {
    const r = await fetch(LITELLM, { signal: AbortSignal.timeout(20000) });
    if (r.ok) { const text = await r.text(); const t = ingest(text); if (t) { try { fs.writeFileSync(own, text); } catch {} return t; } }
  } catch {}
  for (const p of [own, app]) { const t = ingest(readText(p)); if (t) return t; } // stale beats nothing
  return new Map();
}

function rater(table) {
  const memo = new Map();
  const resolve = (model) => {
    const names = [model];
    const slash = model.lastIndexOf("/");
    if (slash >= 0) names.push(model.slice(slash + 1));
    for (const n of [...names]) {
      const c = n.replace(/\[.*\]$/, "").replace(/-\d{8}$/, "");
      if (c !== n) names.push(c);
    }
    for (const n of names) {
      if (table.has(n)) return table.get(n);
      for (const p of ["anthropic/", "openai/", "anthropic.", "openai.", "xai/", "deepseek/"]) if (table.has(p + n)) return table.get(p + n);
    }
    const base = names[names.length - 1];
    let best = null;
    for (const k of table.keys()) if (!k.includes("/") && k.length >= 6 && base.startsWith(k) && (!best || k.length > best.length)) best = k;
    return best ? table.get(best) : null;
  };
  return (raw) => {
    const m = String(raw).toLowerCase();
    if (!memo.has(m)) memo.set(m, resolve(m));
    return memo.get(m);
  };
}

// ---------- log files ----------

function jsonlFiles(dir, since, out = []) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of ents) {
    if (e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) jsonlFiles(p, since, out);
    else if (e.isFile() && e.name.endsWith(".jsonl")) { try { if (fs.statSync(p).mtimeMs >= since) out.push(p); } catch {} }
  }
  return out;
}

/** Calls fn(obj, i) for each line containing needles[i]; other lines are never JSON-parsed. */
function eachLine(file, needles, fn) {
  let buf;
  try { buf = fs.readFileSync(file); } catch { return; }
  const nb = needles.map((n) => Buffer.from(n));
  let s = 0;
  while (s < buf.length) {
    let e = buf.indexOf(10, s);
    if (e < 0) e = buf.length;
    if (e - s > 2) {
      const line = buf.subarray(s, e);
      for (let i = 0; i < nb.length; i++) {
        if (line.includes(nb[i])) {
          let o = null;
          try { o = JSON.parse(line.toString("utf8")); } catch {}
          if (o) fn(o, i);
          break;
        }
      }
    }
    s = e + 1;
  }
}

const int = (v) => (typeof v === "number" && isFinite(v) ? Math.trunc(v) : 0);
const stem = (f) => path.basename(f, ".jsonl");

function serviceFrom(provider) {
  switch (String(provider || "").toLowerCase()) {
    case "anthropic": case "claude": return "claude";
    case "openai-codex": case "codex": case "chatgpt": return "codex";
    case "opencode-go": return "opencodeGo";
    case "opencode": case "opencode-zen": return "opencodeZen";
    case "openai": return "openai";
    default: return "other";
  }
}

// ---------- limit hits ----------

/** "resets 12:40am" → the next time the clock shows 12:40 am after t. */
function clockReset(t, text) {
  const m = /resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)/i.exec(text || "");
  if (!m) return null;
  const d = new Date(t), r = new Date(d.getFullYear(), d.getMonth(), d.getDate(), (+m[1] % 12) + (/pm/i.test(m[3]) ? 12 : 0), +(m[2] || 0));
  if (r.getTime() <= t) r.setDate(r.getDate() + 1);
  return r.getTime();
}
const textOf = (m) => ((m && Array.isArray(m.content) ? m.content : []).find((b) => b && b.type === "text") || {}).text || "";
const windowKind = (mins) => mins <= 360 ? "five_hour" : mins <= 2 * 1440 ? "daily" : mins <= 8 * 1440 ? "seven_day" : "monthly";

function parseClaude(file, rate, out, hits) {
  eachLine(file, ['"usage"', '"rate_limit"'], (o) => {
    if (o.isApiErrorMessage && o.error === "rate_limit") {
      // Claude Code writes this when a request is refused because a plan limit is used up.
      const t = Date.parse(o.timestamp);
      if (!t) return;
      const q = o.quotaLimits || (o.apiErrorParams && o.apiErrorParams.rate_limit_info) || {}, text = textOf(o.message);
      hits.push({ t, svc: "claude", kind: q.rateLimitType || (/weekly/i.test(text) ? "seven_day" : /5-hour/i.test(text) ? "five_hour" : "limit"),
        resetAt: typeof q.resetsAt === "number" ? q.resetsAt * 1000 : clockReset(t, text) });
      return;
    }
    const m = o.message, u = m && m.usage;
    if (!u || !m.model || m.model === "<synthetic>") return;
    const t = Date.parse(o.timestamp);
    if (!t) return;
    const input = int(u.input_tokens), read = int(u.cache_read_input_tokens), write = int(u.cache_creation_input_tokens), output = int(u.output_tokens);
    const w1h = int(u.cache_creation && u.cache_creation.ephemeral_1h_input_tokens), w5m = Math.max(0, write - w1h);
    const r = rate(m.model);
    const cost = r ? input * r.input + output * r.output + read * r.cacheRead + w5m * r.cacheWrite + w1h * r.cacheWrite1h : 0;
    out.push({ t, tool: "claude-code", svc: "claude", model: m.model, tokens: input + read + write + output, cost,
      session: o.sessionId || stem(file), key: m.id ? `c:${m.id}:${o.requestId || ""}` : null });
  });
}

function parseCodex(file, rate, out, hits, near) {
  let model = "gpt-5-codex", lastTotal = -1;
  eachLine(file, ['"token_count"', '"turn_context"', "usage limit"], (o, kind) => {
    const p = o.payload;
    if (!p) return;
    if (kind === 1) { if (p.model) model = p.model; return; }
    const t = Date.parse(o.timestamp);
    if (!t) return;
    if (kind === 2) {
      if (p.type === "error" && /usage limit/i.test(String(p.message || ""))) hits.push({ t, svc: "codex", kind: "limit", resetAt: null });
      return;
    }
    if (p.type !== "token_count") return;
    // Codex logs how much of each limit window is used; 100% means it locked you out.
    for (const w of [p.rate_limits && p.rate_limits.primary, p.rate_limits && p.rate_limits.secondary]) {
      if (!w || typeof w.used_percent !== "number") continue;
      const resetAt = typeof w.resets_at === "number" ? w.resets_at * 1000 : typeof w.resets_in_seconds === "number" ? t + w.resets_in_seconds * 1000 : null;
      const k = windowKind(w.window_minutes || 0);
      if (w.used_percent >= 100) hits.push({ t, svc: "codex", kind: k, resetAt });
      else near.push({ t, svc: "codex", kind: k, pct: w.used_percent, resetAt });
    }
    if (!p.info || !p.info.last_token_usage) return;
    const total = int(p.info.total_token_usage && p.info.total_token_usage.total_tokens);
    if (total === lastTotal) return;
    lastTotal = total;
    const l = p.info.last_token_usage;
    const cached = int(l.cached_input_tokens), write = int(l.cache_write_input_tokens), output = int(l.output_tokens);
    const input = Math.max(0, int(l.input_tokens) - cached - write);
    const r = rate(model);
    const cost = r ? input * r.input + cached * r.cacheRead + write * r.cacheWrite + output * r.output : 0;
    out.push({ t, tool: "codex", svc: "codex", model, tokens: input + cached + write + output, cost, session: stem(file) });
  });
}

const LIMIT_ERROR = /usage limit|UsageLimitError|hit your .{0,40}limit|limit (?:has been )?reached/i;

function parsePi(file, rate, out, hits) {
  eachLine(file, ['"usage"', '"errorMessage"'], (o) => {
    const m = o.message;
    if (m && typeof m.errorMessage === "string" && LIMIT_ERROR.test(m.errorMessage)) {
      const t = Date.parse(o.timestamp) || (typeof m.timestamp === "number" ? m.timestamp : 0);
      const mins = /try again in ~?(\d+)\s*min/i.exec(m.errorMessage);
      if (t) hits.push({ t, svc: serviceFrom(m.provider), kind: "limit", resetAt: mins ? t + +mins[1] * 60000 : null });
    }
    const u = m && m.usage;
    if (!u) return;
    const t = Date.parse(o.timestamp) || (typeof m.timestamp === "number" ? m.timestamp : 0);
    if (!t) return;
    const model = m.model || "unknown", provider = m.provider;
    const input = int(u.input), output = int(u.output), read = int(u.cacheRead), write = int(u.cacheWrite);
    let cost = (u.cost && typeof u.cost.total === "number") ? u.cost.total : 0;
    if (!cost) { const r = rate(model); if (r) cost = input * r.input + output * r.output + read * r.cacheRead + write * r.cacheWrite; }
    out.push({ t, tool: "pi", svc: serviceFrom(provider), model: provider ? `${provider}/${model}` : model,
      tokens: input + output + read + write, cost, session: stem(file) });
  });
}

function scanOpenCode(since, out) {
  const db = path.join(HOME, ".local", "share", "opencode", "opencode.db");
  if (!fs.existsSync(db)) return;
  let sqlite;
  const warn = process.emitWarning;
  process.emitWarning = () => {}; // node:sqlite prints an "experimental" warning on some versions
  try { sqlite = require("node:sqlite"); } catch { return; } finally { process.emitWarning = warn; }
  try {
    const d = new sqlite.DatabaseSync(db, { readOnly: true });
    const rows = d.prepare("SELECT session_id, time_created, data FROM session_message WHERE type = 'assistant' AND time_created >= ?").all(since);
    d.close();
    for (const row of rows) {
      let o;
      try { o = JSON.parse(row.data); } catch { continue; }
      const tk = o && o.tokens;
      if (!tk) continue;
      const cache = tk.cache || {};
      const input = int(tk.input), output = int(tk.output) + int(tk.reasoning), read = int(cache.read), write = int(cache.write);
      if (input + output + read + write === 0) continue;
      const mo = o.model || {};
      out.push({ t: Number(row.time_created), tool: "opencode", svc: serviceFrom(mo.providerID || o.providerID),
        model: mo.id || o.modelID || "unknown", tokens: input + output + read + write, cost: typeof o.cost === "number" ? o.cost : 0,
        session: String(row.session_id) });
    }
  } catch {}
}

async function scan() {
  const since = Date.now() - PERIODS["30d"] * 1000;
  const rate = rater(await loadPrices());
  const recs = [], hits = [], near = [];
  const roots = (dirs) => dirs.flatMap((d) => jsonlFiles(path.join(HOME, ...d.split("/")), since));
  for (const f of roots([".claude/projects", ".config/claude/projects"])) parseClaude(f, rate, recs, hits);
  for (const f of roots([".codex/sessions", ".codex/archived_sessions"])) parseCodex(f, rate, recs, hits, near);
  for (const f of roots([".pi/agent/sessions"])) parsePi(f, rate, recs, hits);
  scanOpenCode(since, recs);
  const seen = new Set();
  return {
    recs: recs.filter((r) => r.t >= since && (!r.key || (!seen.has(r.key) && seen.add(r.key)))),
    hits: clusterHits(hits.filter((h) => h.t >= since)),
    near: near.filter((n) => n.t >= since),
  };
}

/** Many refused requests can belong to one lockout: same plan and limit, same reset (or within 2 h when the reset is unknown). */
function clusterHits(hits) {
  hits.sort((a, b) => a.t - b.t);
  const out = [];
  for (const h of hits) {
    let prev = null;
    for (let i = out.length - 1; i >= 0; i--) if (out[i].svc === h.svc) { prev = out[i]; break; }
    const same = prev && (h.resetAt && prev.resetAt ? Math.abs(h.resetAt - prev.resetAt) < 15 * 60000 && (prev.kind === h.kind || prev.kind === "limit" || h.kind === "limit")
      : h.t - prev.last < 2 * 3600000);
    if (same) { prev.last = h.t; if (!prev.resetAt && h.resetAt) prev.resetAt = h.resetAt; if (prev.kind === "limit") prev.kind = h.kind; }
    else out.push({ ...h, last: h.t });
  }
  // A lockout of unknown type that resets within ~5 h was the session window; longer means weekly.
  return out.map(({ last, ...h }) => (h.kind === "limit" && h.resetAt ? { ...h, kind: h.resetAt - h.t > 6 * 3600000 ? "seven_day" : "five_hour" } : h));
}

// ---------- plans, read from files the CLIs keep (never the Keychain, never a network call) ----------

function jsonFile(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } }

function detectPlans() {
  const plans = {};
  // Claude: ~/.claude.json records the subscription type of the signed-in account.
  const acct = (jsonFile(path.join(HOME, ".claude.json")) || {}).oauthAccount;
  const creds = ((jsonFile(path.join(HOME, ".claude", ".credentials.json")) || {}).claudeAiOauth) || {};
  const kind = String((acct && acct.organizationType) || creds.subscriptionType || "").toLowerCase();
  const tier = String((acct && acct.organizationRateLimitTier) || creds.rateLimitTier || "").toLowerCase();
  if (kind.includes("max")) plans.claude = tier.includes("20x") ? "Claude Max 20x" : "Claude Max 5x";
  else if (kind.includes("team") || kind.includes("enterprise")) plans.claude = "Claude Team";
  else if (kind.includes("pro")) plans.claude = "Claude Pro";
  else if (acct) plans.claude = "Claude Pro";
  // Codex: the ChatGPT plan is a claim inside the stored id token.
  try {
    const a = jsonFile(path.join(HOME, ".codex", "auth.json"));
    const tok = a && a.tokens && a.tokens.id_token;
    if (tok) {
      const claims = JSON.parse(Buffer.from(tok.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"));
      const p = String((claims["https://api.openai.com/auth"] || {}).chatgpt_plan_type || "").toLowerCase();
      plans.codex = p.includes("pro") ? "ChatGPT Pro" : (p.includes("team") || p.includes("business")) ? "ChatGPT Business" : p ? "ChatGPT Plus" : undefined;
    }
  } catch {}
  return plans;
}

// ---------- numbers per period (no project names, no paths) ----------

function periodData({ recs, hits, near }, key, now) {
  const secs = PERIODS[key], since = now - secs * 1000;
  const rs = recs.filter((r) => r.t >= since);
  const services = {}, models = {}, sessions = new Set();
  const hours = Array(24).fill(0), weekdays = Array(7).fill(0);
  const w = (r) => (r.cost > 0 ? r.cost : r.tokens * 1e-7);
  for (const r of rs) {
    const s = services[r.svc] || (services[r.svc] = { cost: 0, tokens: 0 });
    s.cost += r.cost; s.tokens += r.tokens;
    const name = r.model.split("/").pop();
    models[name] = (models[name] || 0) + r.cost;
    sessions.add(r.tool + "|" + r.session);
    const d = new Date(r.t);
    hours[d.getHours()] += w(r);
    weekdays[d.getDay()] += w(r);
  }
  // Bars: hourly for 24 h, daily otherwise, ending now.
  const n = key === "24h" ? 24 : key === "7d" ? 7 : 30;
  const nowD = new Date(now);
  const starts = Array.from({ length: n }, (_, i) => key === "24h"
    ? new Date(nowD.getFullYear(), nowD.getMonth(), nowD.getDate(), nowD.getHours() - (n - 1 - i)).getTime()
    : new Date(nowD.getFullYear(), nowD.getMonth(), nowD.getDate() - (n - 1 - i)).getTime());
  const bars = Array(n).fill(0);
  for (const r of rs) { for (let i = n - 1; i >= 0; i--) if (starts[i] <= r.t) { bars[i] += w(r); break; } }
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const labels = starts.map((t, i) => {
    const d = new Date(t);
    if (key === "24h") return d.getHours() % 6 === 0 ? String(d.getHours()).padStart(2, "0") : "";
    if (key === "7d") return days[d.getDay()];
    return (n - 1 - i) % 7 === 0 ? String(d.getDate()) : "";
  });
  let peak = -1;
  bars.forEach((v, i) => { if (v > 0 && (peak < 0 || v > bars[peak])) peak = i; });
  return {
    seconds: secs, services, sessions: sessions.size,
    models: Object.entries(models).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([name, cost]) => ({ name, cost })),
    hours, weekdays, bars, barLabels: labels, peakBar: peak >= 0 ? starts[peak] : null,
    limits: {
      hits: hits.filter((h) => h.t >= since).map((h) => ({ t: h.t, svc: h.svc, kind: h.kind, resetAt: h.resetAt })),
      closest: near.filter((n) => n.t >= since).sort((a, b) => b.pct - a.pct).map((n) => ({ t: n.t, svc: n.svc, kind: n.kind, pct: n.pct }))[0] || null,
    },
  };
}

// ---------- the command ----------

const money = (v) => (v >= 100 ? "$" + Math.round(v) : "$" + v.toFixed(2));

function opener(file) {
  if (process.platform === "darwin") return ["open", [file]];
  if (process.platform === "win32") return ["cmd", ["/c", "start", "", file]];
  return ["xdg-open", [file]];
}

async function wrapped({ say, flags, version }) {
  say("Reading your Claude Code, Codex, Pi and OpenCode logs (last 30 days)…");
  const scanned = await scan(), recs = scanned.recs;
  if (!recs.length) {
    say("No usage found. Tally reads ~/.claude/projects, ~/.codex/sessions, ~/.pi/agent/sessions and OpenCode's database.");
    return;
  }
  const now = Date.now();
  const data = {
    generated: now, version, plans: detectPlans(),
    periods: Object.fromEntries(Object.keys(PERIODS).map((k) => [k, periodData(scanned, k, now)])),
    defaultPeriod: ["24h", "7d", "30d"].includes(flags.period) ? flags.period : "30d",
  };
  const dir = path.join(__dirname, "..", "wrapped");
  const font = fs.readFileSync(path.join(dir, "newsreader.woff2")).toString("base64");
  const html = fs.readFileSync(path.join(dir, "page.html"), "utf8")
    .replace("__FONT__", font)
    .replace("/*__DATA__*/null", JSON.stringify(data).replace(/</g, "\\u003c"));
  const outDir = path.join(os.tmpdir(), "tally-wrapped");
  fs.mkdirSync(outDir, { recursive: true });
  const out = path.join(outDir, `tally-wrapped-${new Date(now - new Date(now).getTimezoneOffset() * 60000).toISOString().slice(0, 10)}.html`);
  fs.writeFileSync(out, html);

  const m = data.periods["30d"], api = Object.values(m.services).reduce((s, v) => s + v.cost, 0);
  const tokens = Object.values(m.services).reduce((s, v) => s + v.tokens, 0);
  const tk = tokens >= 1e9 ? (tokens / 1e9).toFixed(2) + "B" : (tokens / 1e6).toFixed(1) + "M";
  say(`\n  Last 30 days: ${money(api)} at API prices · ${tk} tokens · ${m.sessions} sessions`);
  if (m.limits.hits.length) say(`  You hit a plan limit ${m.limits.hits.length} time${m.limits.hits.length > 1 ? "s" : ""}.`);
  say(`  Your Wrapped: ${out}`);
  if (!flags["no-open"]) {
    const [bin, argv] = opener(out);
    try { spawn(bin, argv, { stdio: "ignore", detached: true }).unref(); say("  Opened it in your browser."); }
    catch { say("  Open that file in your browser."); }
  }
  say("\n  Nothing was uploaded: the page is a local file built from your logs.");
  if (process.platform === "darwin") say("  Want this live in your menu bar? npx tally-menubar");
}

module.exports = { wrapped, scan, periodData, detectPlans };
