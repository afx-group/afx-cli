#!/bin/bash
# afx-install-claude-hooks.sh: install/refresh the AFX Claude Code guard on this machine (R20 + R21).
# Copies the guard scripts to ~/.claude/hooks/afx-guard/ (a standalone copy, so hooks never depend
# on a repo checkout's state) and merges the hook entries into ~/.claude/settings.json, keeping every
# other setting. Idempotent: re-running replaces AFX entries, never duplicates them.
#   scripts/afx-guard/afx-install-claude-hooks.sh            install / refresh
#   scripts/afx-guard/afx-install-claude-hooks.sh --remove   remove AFX hook entries (scripts stay)
#   scripts/afx-guard/afx-install-claude-hooks.sh --check    change nothing; print what is installed and whether it matches this
#                                                            checkout (exit 0 = everything installed and identical, 1 = not)
# ONE command installs everything: the policy guard (with its self-protection), the peer-protocol hooks (afx-peer-limit.mjs on
# SendMessage, afx-owner-decisions-guard.mjs on Bash|Write|Edit|MultiEdit|NotebookEdit) and their scripts (afx-owner-ask.sh,
# afx-owner-decide.sh, afx-owner-decisions.sh, peer-lanes.json). Once the guard is installed, agents cannot run this script or
# write to the install directory: the OWNER runs it, typed with the ! prefix.
# OPTIONAL (off by default; the defaults above are unchanged): AFX_INSTALL_STANDARD_CHECK=1 also copies the
# AFX Operating Standard checker (afx-standard-check.sh + helpers) to ~/.claude/hooks/afx-guard/standard-check/
# so it can be run anywhere. It never installs a git hook by itself; that is the separate opt-in
#   afx-standard-check.sh install-hook [repo]
# Mac, Linux (Replit) and Windows Git Bash. Needs node (every AFX machine has it for pnpm).
set -eu
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# The documented install runs from a `git archive` export (not a checkout), so rev-parse fails there and SOURCE.txt
# used to say "unknown" on every machine. Pass the hub commit in: AFX_SOURCE_SHA=$(git -C <hub> rev-parse --short origin/main).
SRC_SHA="${AFX_SOURCE_SHA:-$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
DEST="$HOME/.claude/hooks/afx-guard"
SETTINGS="$HOME/.claude/settings.json"
GUARD_FILES="afx-platform.sh afx-config.mjs afx-config-defaults.sh afx-preflight.sh afx-fragment-audit.sh afx-preserve-all.sh afx-sweep.sh afx-where-am-i.sh afx-workspace-status.sh afx-freeze.sh afx-approve-model.sh afx-approve-spend.sh afx-lock.sh afx-gate-slots.sh afx-gate-run.sh afx-mask-secrets.sh afx-digest.mjs claude-hooks/afx-policy-guard.mjs claude-hooks/afx-agent-budget.mjs claude-hooks/afx-statusline.sh claude-hooks/afx-local-hint.mjs claude-hooks/afx-token-hygiene.mjs registry/remote-probes.txt"
PEER_FILES="afx-peer-limit.mjs afx-board-hook.mjs afx-board.sh afx-board.mjs afx-owner-decisions-guard.mjs afx-owner-ask.sh afx-owner-decide.sh afx-owner-decisions.sh peer-lanes.json"
# The tenant preset (private tier: AFX's own values for afx-config.mjs / afx-config-defaults.sh). Copied only when it exists in the
# source tree, so a core-only tree installs fine; present on AFX machines, so their values stay exactly as before.
PRESET_FILES=""; for _p in afx-config.afx.json afx-config-defaults.afx.sh; do [ -f "$SRC/$_p" ] && PRESET_FILES="$PRESET_FILES $_p"; done; PRESET_FILES="${PRESET_FILES# }"
_HUB_NAME=$(sed -n 's/^[[:space:]]*"hubRepo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/afx-config.afx.json" 2>/dev/null | head -1)
if [ "${1:-}" = "--check" ]; then
  # Read-only report. Files: every file this installer would copy, compared byte for byte with this checkout.
  rc=0; echo "afx-install-claude-hooks --check (source: $SRC @ $SRC_SHA)"
  [ -f "$DEST/SOURCE.txt" ] && echo "installed: $(cat "$DEST/SOURCE.txt")" || { echo "installed: nothing (no $DEST/SOURCE.txt)"; rc=1; }
  LIST="$GUARD_FILES $PEER_FILES $PRESET_FILES"
  for f in $LIST; do
    b="$DEST/$(basename "$f")"
    if [ ! -f "$b" ]; then echo "  MISSING  $(basename "$f")"; rc=1
    elif ! cmp -s "$SRC/$f" "$b"; then echo "  DIFFERS  $(basename "$f")"; rc=1
    fi
  done
  [ "$rc" = 0 ] && echo "  files: all present and identical to this checkout"
  DEST="$DEST" SETTINGS="$SETTINGS" node --input-type=module -e '
import { readFileSync, existsSync } from "node:fs";
const { DEST, SETTINGS } = process.env;
const d = existsSync(SETTINGS) ? JSON.parse(readFileSync(SETTINGS, "utf8")) : {};
const want = [["SessionStart", "", "afx-policy-guard"], ["UserPromptSubmit", "", "afx-policy-guard"], ["PreToolUse", "Bash|PowerShell", "afx-policy-guard"],
  ["PreToolUse", "Write|Edit|MultiEdit|NotebookEdit", "afx-policy-guard"], ["PreToolUse", "Agent|Task", "afx-policy-guard"], ["Stop", "", "afx-policy-guard"],
  ["PreToolUse", "SendMessage", "afx-peer-limit"], ["UserPromptSubmit", "", "afx-token-hygiene"], ["PreToolUse", "Read|Bash|ScheduleWakeup", "afx-token-hygiene"], ["PreToolUse", "Bash|Write|Edit|MultiEdit|NotebookEdit", "afx-owner-decisions-guard"],
  ["UserPromptSubmit", "", "afx-board-hook"], ["PostToolUse", "Bash|Read|Edit|Write", "afx-board-hook"]];
let missing = 0;
for (const [ev, matcher, script] of want) {
  const ok = (d.hooks?.[ev] || []).some((e) => (e.matcher || "") === matcher && (e.hooks || []).some((h) => (h.command || "").includes(`${DEST}/${script}`)));
  if (!ok) { missing++; console.log(`  HOOK MISSING  ${ev}${matcher ? " [" + matcher + "]" : ""} -> ${script}`); }
}
if (!missing) console.log("  settings.json: all AFX hook entries present");
process.exit(missing ? 1 : 0);
' || rc=1
  exit $rc
fi
# Landed-source check (2026-10-23): agents may run this installer after their change landed (the policy guard allows only the bare
# form), so a source tree that is dirty or not contained in origin/main is refused: an unreviewed guard never goes live. Skipped for
# a `git archive` export (no checkout) and for --remove; the owner overrides with AFX_INSTALL_ALLOW_UNLANDED=1 on a ! command.
if [ "${1:-}" != "--remove" ] && [ -z "${AFX_SOURCE_SHA:-}" ] && [ "${AFX_INSTALL_ALLOW_UNLANDED:-0}" != "1" ] \
   && git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$SRC" fetch -q origin main 2>/dev/null || true
  if [ -n "$(git -C "$SRC" status --porcelain -- . 2>/dev/null)" ]; then
    echo "afx-install-claude-hooks: REFUSED: $SRC has uncommitted changes; land them first (afx-land.sh), then install from a clean checkout of main" >&2; exit 3
  fi
  if ! git -C "$SRC" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "afx-install-claude-hooks: REFUSED: $SRC HEAD $SRC_SHA is not contained in origin/main; land the change first, then install from main" >&2; exit 3
  fi
fi
mkdir -p "$DEST"
if [ "${1:-}" != "--remove" ]; then
  for f in $PEER_FILES; do cp -p "$SRC/$f" "$DEST/$f"; done
  # Preset first: the neutral afx-config files below must never be live without it on a machine that has one.
  for f in $PRESET_FILES; do cp -p "$SRC/$f" "$DEST/$f"; done
  for f in $GUARD_FILES; do
    cp -p "$SRC/$f" "$DEST/$(basename "$f")"
  done
  chmod +x "$DEST"/*.sh "$DEST"/*.mjs
  echo "source: ${_HUB_NAME:-afx-hub} $SRC_SHA installed $(date '+%Y-%m-%d %H:%M')" > "$DEST/SOURCE.txt"
  # Legacy Lenovo guard: kept as .retired (never deleted); its settings entry is dropped below.
  [ -f "$HOME/.claude/hooks/allforx-guard.js" ] && mv "$HOME/.claude/hooks/allforx-guard.js" "$HOME/.claude/hooks/allforx-guard.js.retired" && echo "retired ~/.claude/hooks/allforx-guard.js (rules now in afx-policy-guard)"
fi
if [ "${1:-}" != "--remove" ] && [ "${AFX_INSTALL_STANDARD_CHECK:-0}" = "1" ]; then
  SC="$DEST/standard-check"; mkdir -p "$SC/scripts/afx-guard" "$SC/scripts/auth-conformance"
  for f in afx-standard-check.sh afx-standard-check-brand.mjs afx-expo-default-assets.sha256 afx-release-claims-verify.sh replit-hosts.txt; do cp -p "$SRC/$f" "$SC/scripts/afx-guard/$f"; done
  cp -p "$SRC/../auth-conformance/check.mjs" "$SC/scripts/auth-conformance/check.mjs"
  chmod +x "$SC/scripts/afx-guard/"*.sh "$SC/scripts/afx-guard/"*.mjs
  echo "standard-check installed: $SC/scripts/afx-guard/afx-standard-check.sh"
fi
[ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
MODE="${1:-install}" DEST="$DEST" SETTINGS="$SETTINGS" node --input-type=module -e '
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const { MODE, DEST, SETTINGS } = process.env;
const d = existsSync(SETTINGS) ? JSON.parse(readFileSync(SETTINGS, "utf8")) : {};
const where = `${DEST}/afx-where-am-i.sh --hook`;
const policy = `node ${DEST}/afx-policy-guard.mjs`;
const hint = `node ${DEST}/afx-local-hint.mjs`;
const isAfx = (e) => (e.hooks || []).some((h) => /afx-guard\/(afx-where-am-i|afx-policy-guard|afx-agent-budget|afx-local-hint|afx-token-hygiene|afx-peer-limit|afx-board-hook|afx-owner-decisions-guard)/.test(h.command || ""));
d.hooks = d.hooks || {};
// The Lenovo`s 2026-10-14 allforx-guard.js is retired into afx-policy-guard (same rules plus the AFX_OWNER_OK path); drop its entry.
const isLegacy = (e) => MODE !== "--remove" && (e.hooks || []).some((h) => /[\\/]hooks[\\/]allforx-guard\.js/.test(h.command || ""));
for (const k of Object.keys(d.hooks)) { d.hooks[k] = d.hooks[k].filter((e) => !isAfx(e) && !isLegacy(e)); if (!d.hooks[k].length) delete d.hooks[k]; }
if (MODE !== "--remove") {
  const add = (ev, entry) => (d.hooks[ev] = [...(d.hooks[ev] || []), entry]);
  const cmd = (c, t) => ({ type: "command", command: c, timeout: t });
  add("SessionStart", { hooks: [cmd(where, 20), cmd(policy, 10)] });
  add("UserPromptSubmit", { hooks: [cmd(policy, 10)] });
  // Always on origin/main: advisory line (and a safe fast-forward of a clean main checkout) at every prompt; fetch is rate limited.
  add("UserPromptSubmit", { hooks: [cmd(where, 25)] });
  add("PreToolUse", { matcher: "Write|Edit|MultiEdit|NotebookEdit", hooks: [cmd(where, 10), cmd(policy, 10)] });
  add("PreToolUse", { matcher: "Bash|PowerShell", hooks: [cmd(policy, 30)] });
  add("PreToolUse", { matcher: "Agent|Task", hooks: [cmd(policy, 10)] });
  add("PreToolUse", { matcher: "Agent|Task|Workflow", hooks: [cmd(`node ${DEST}/afx-agent-budget.mjs`, 10)] });
  add("PostToolUse", { matcher: "Write|Edit|MultiEdit", hooks: [cmd(policy, 10)] });
  // Token-saving hints (advisory, never block): [local] tag -> local_draft/afx-local; big gate output -> digest wrapper.
  add("UserPromptSubmit", { hooks: [cmd(hint, 10)] });
  add("PostToolUse", { matcher: "Bash", hooks: [cmd(hint, 10)] });
  // Token hygiene (advisory, never blocks, fail-open; docs TOKEN_EFFICIENCY.md): long transcript, unbounded Read/Bash output, short wake-ups.
  const hyg = `node ${DEST}/afx-token-hygiene.mjs`;
  add("UserPromptSubmit", { hooks: [cmd(hyg, 10)] });
  add("PreToolUse", { matcher: "Read|Bash|ScheduleWakeup", hooks: [cmd(hyg, 10)] });
  // Peer protocol (PEER_PROTOCOL.md): send-side loop limits and kill switch; agent-write guard for the owner-decisions ledger.
  add("PreToolUse", { matcher: "SendMessage", hooks: [cmd(`node ${DEST}/afx-peer-limit.mjs`, 10)] });
  add("PreToolUse", { matcher: "Bash|Write|Edit|MultiEdit|NotebookEdit", hooks: [cmd(`node ${DEST}/afx-owner-decisions-guard.mjs`, 10)] });
  // Agent board (docs/ops/AGENT_BOARD.md): unread board messages as additional context; never blocks, fail-open, PostToolUse throttled to 45 s per session.
  const board = `node ${DEST}/afx-board-hook.mjs`;
  add("UserPromptSubmit", { hooks: [cmd(board, 5)] });
  add("PostToolUse", { matcher: "Bash|Read|Edit|Write", hooks: [cmd(board, 5)] });
  add("Stop", { hooks: [cmd(policy, 20)] });
  add("SubagentStop", { hooks: [cmd(policy, 20)] });
}
// Status line: set it only when none is configured, or when the existing one is ours.
const sl = `${DEST}/afx-statusline.sh`;
if (MODE === "--remove") { if (/afx-statusline/.test(d.statusLine?.command || "")) delete d.statusLine; }
else if (!d.statusLine || /afx-statusline/.test(d.statusLine.command || "")) d.statusLine = { type: "command", command: sl, padding: 0 };
writeFileSync(SETTINGS, JSON.stringify(d, null, 2) + "\n");
console.log(MODE === "--remove" ? "AFX hooks removed" : `AFX hooks installed: ${Object.keys(d.hooks).join(", ")} (policy guard with self-protection, peer limiter on SendMessage, owner-decisions guard). Verify any time with: afx-install-claude-hooks.sh --check`);
'
