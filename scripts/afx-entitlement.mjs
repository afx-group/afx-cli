#!/usr/bin/env node
// afx-entitlement.mjs: the per-seat licence check behind AFX CLI Pro. A licence is a signed token (Ed25519) issued by the vendor's
// server after a paid subscription (Stripe customer -> entitlement `afx_cli:pro`, seat count = subscription quantity). The client
// verifies it OFFLINE against a public key, so a check needs no network; the valuable text and evaluation logic are NOT in this
// client at all: they are served by the vendor's server only to a valid token (afx-pack.mjs).
//
//   afx license status [--json]     verdict only: plan, seats, expiry, valid/expired/none. Never prints the token.
//   afx license activate <token>    verify, then store in ~/.afx/license.token (mode 600). `--file F` reads the token from a file.
//   afx license clear               remove the stored token
//   afx license machine             print this machine's id (give it when requesting a licence: the token is bound to it)
//   afx license check <feature>     exit 0 entitled, 1 not entitled, 2 usage. Prints a one-line verdict. (used by Pro commands)
//
// Token: AFX1.<base64url JSON payload>.<base64url Ed25519 signature over the first two dot parts' payload bytes>
// payload: { v:1, sub, plan, features:[...], seats, iat, exp, api }  (times are epoch seconds; api = the issuing server's base URL)
// Public key: $AFX_LICENSE_PUBKEY_FILE, else license-public-key.pem next to this script. Without a key nothing is entitled
// (fail closed): the key ships with a release build once the owner has generated the signing key pair (not done yet).
// HONESTY: anything that reaches a local machine can be copied. This check stops casual use of Pro commands and keeps the high-value
// text off free installs; it is not DRM.
import { createPublicKey, createPrivateKey, createHash, verify, sign } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, unlinkSync, realpathSync } from "node:fs";
import { homedir, hostname, platform, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const isMain = () => { try { return !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); } catch { return false; } };
export const PREFIX = "AFX1";
export const PRO_FEATURE = "afx_cli:pro";

const b64u = (buf) => Buffer.from(buf).toString("base64url");
const home = (env = process.env) => env.HOME || env.USERPROFILE || homedir();
export const tokenPath = (env = process.env) => join(home(env), ".afx", "license.token");

// Stable, non-secret id of this machine+user (a hash; sent as X-Afx-Machine and bound into the token at issue time).
export function machineId() {
  let u = ""; try { u = userInfo().username; } catch {}
  return createHash("sha256").update(`${hostname()}|${platform()}|${u}`).digest("hex").slice(0, 32);
}

export function loadPublicKey(env = process.env) {
  const f = env.AFX_LICENSE_PUBKEY_FILE || join(HERE, "license-public-key.pem");
  if (!existsSync(f)) return null;
  try { return createPublicKey(readFileSync(f, "utf8")); } catch { return null; }
}

// Sign a payload (vendor server and tests only; the private key never ships in any build).
export function signToken(payload, privateKeyPem) {
  const body = b64u(JSON.stringify({ v: 1, ...payload }));
  const sig = sign(null, Buffer.from(body), createPrivateKey(privateKeyPem));
  return `${PREFIX}.${body}.${b64u(sig)}`;
}

// -> { state: "none"|"invalid"|"expired"|"valid", reason?, payload? }. Never throws.
export function verifyToken(token, { key, now = Math.floor(Date.now() / 1000) } = {}) {
  if (!token) return { state: "none", reason: "no licence installed" };
  const parts = String(token).trim().split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return { state: "invalid", reason: "not an AFX licence token" };
  if (!key) return { state: "invalid", reason: "this build has no licence verification key" };
  let payload;
  try {
    if (b64u(Buffer.from(parts[2], "base64url")) !== parts[2]) return { state: "invalid", reason: "malformed signature" };
    if (!verify(null, Buffer.from(parts[1]), key, Buffer.from(parts[2], "base64url"))) return { state: "invalid", reason: "signature does not match" };
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch { return { state: "invalid", reason: "malformed token" }; }
  if (payload.v !== 1 || !Array.isArray(payload.features) || !Number.isFinite(payload.exp)) return { state: "invalid", reason: "unsupported token contents" };
  if (payload.exp <= now) return { state: "expired", reason: `expired ${new Date(payload.exp * 1000).toISOString().slice(0, 10)}`, payload };
  return { state: "valid", payload };
}

export function readToken(env = process.env) {
  if (env.AFX_LICENSE) return env.AFX_LICENSE.trim();
  const f = tokenPath(env);
  try { return existsSync(f) ? readFileSync(f, "utf8").trim() : ""; } catch { return ""; }
}

export function entitlement(feature = PRO_FEATURE, { env = process.env, now } = {}) {
  const r = verifyToken(readToken(env), { key: loadPublicKey(env), now });
  const entitled = r.state === "valid" && r.payload.features.includes(feature);
  return { ...r, entitled, feature, reason: entitled ? undefined : r.reason || (r.state === "valid" ? `licence does not include ${feature}` : undefined) };
}

// Client config for the hosted MCP endpoint. The server URL comes from the licence (`api` claim) or AFX_API_BASE_URL, never from a
// built-in host; the token itself is never printed (the client reads it from an environment variable).
export function mcpConfig({ env = process.env } = {}) {
  const e = entitlement(PRO_FEATURE, { env });
  const api = String((e.entitled && e.payload.api) || env.AFX_API_BASE_URL || "").replace(/\/$/, "");
  if (!/^https?:\/\//.test(api)) return { code: 2, text: "no server known: activate a licence (afx license activate <token>) or set AFX_API_BASE_URL to your AFX server" };
  const headers = e.entitled
    ? { Authorization: "Bearer ${AFX_LICENSE}", "X-Afx-Machine": machineId() }
    : { Authorization: "Bearer ${AFX_API_KEY}" };
  return { code: 0, text: JSON.stringify({ mcpServers: { afx: { type: "http", url: `${api}/mcp`, headers } } }, null, 2), licensed: e.entitled };
}

const verdictLine = (e) => e.entitled
  ? `entitled: ${e.feature} (plan ${e.payload.plan || "unknown"}, ${e.payload.seats || 1} seat(s), valid until ${new Date(e.payload.exp * 1000).toISOString().slice(0, 10)})`
  : `not entitled: ${e.feature}: ${e.reason || e.state}. AFX CLI Pro is a per-seat subscription; the free core stays free. Run: afx license status`;

export function main(argv, { out = (s) => console.log(s), err = (s) => console.error(s), env = process.env } = {}) {
  const [cmd, ...rest] = argv;
  if (cmd === "status") {
    const e = entitlement(PRO_FEATURE, { env });
    if (rest.includes("--json")) out(JSON.stringify({ state: e.state, entitled: e.entitled, plan: e.payload?.plan, seats: e.payload?.seats, expires: e.payload ? new Date(e.payload.exp * 1000).toISOString() : undefined, reason: e.reason }));
    else out(e.entitled ? verdictLine(e) : `licence: ${e.state}${e.reason ? ` (${e.reason})` : ""}. Free core commands work; AFX CLI Pro commands need a licence.`);
    return 0;
  }
  if (cmd === "activate") {
    let token = rest[0] && rest[0] !== "--file" ? rest[0] : "";
    if (rest[0] === "--file") { try { token = readFileSync(rest[1], "utf8").trim(); } catch { err("afx license: cannot read the token file"); return 2; } }
    if (!token) { err("usage: afx license activate <token> | --file F"); return 2; }
    const r = verifyToken(token, { key: loadPublicKey(env) });
    if (r.state !== "valid") { err(`afx license: not activated: ${r.state}: ${r.reason}`); return 1; }
    const f = tokenPath(env); mkdirSync(dirname(f), { recursive: true });
    writeFileSync(f, token + "\n", { mode: 0o600 }); try { chmodSync(f, 0o600); } catch {}
    out(`licence activated: plan ${r.payload.plan || "unknown"}, ${r.payload.seats || 1} seat(s), valid until ${new Date(r.payload.exp * 1000).toISOString().slice(0, 10)}`);
    return 0;
  }
  if (cmd === "mcp-config") {
    const r = mcpConfig({ env });
    if (r.code !== 0) { err(r.text); return r.code; }
    out(r.text);
    err(r.licensed ? "Set AFX_LICENSE to your licence token in the client's environment (afx license machine prints this machine id)." : "No Pro licence: use an AFX API key as AFX_API_KEY (free seats get verdicts and pointers, not rule text).");
    return 0;
  }
  if (cmd === "machine") { out(machineId()); return 0; }
  if (cmd === "clear") { try { unlinkSync(tokenPath(env)); out("licence removed"); } catch { out("no stored licence"); } return 0; }
  if (cmd === "check") {
    const feature = rest[0];
    if (!feature) { err("usage: afx license check <feature>"); return 2; }
    const e = entitlement(feature, { env });
    out(verdictLine(e)); return e.entitled ? 0 : 1;
  }
  err("usage: afx license status [--json] | activate <token> | machine | clear | check <feature>");
  return 2;
}

if (isMain()) process.exit(main(process.argv.slice(2)));
