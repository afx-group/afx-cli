#!/bin/bash
# afx-ratchet.sh: an error ratchet for repos whose typecheck / test baseline is red on main.
# A red baseline means nobody can prove "green", but everybody can prove "no new errors". This tool records the existing
# errors in a committed JSON file and fails ONLY on regressions (a new tsc error line, a new failing test), prints the
# burn-down when the numbers fall, and (with --lower) rewrites the baseline so the gain can never be given back.
# Deterministic, no network, no model: it only parses logs (python3 standard library).
#
#   afx-ratchet.sh record  --baseline F --scope S [--dir D] [--tsc-log L | --tsc-cmd C] [--tests-log L | --tests-cmd C] [--loose] [--force]
#   afx-ratchet.sh check   --baseline F --scope S [--tsc-log L] [--tests-log L] [--lower]
#   afx-ratchet.sh run     --baseline F [--scope S] [--lower]       run the commands stored in the baseline, then check
#   afx-ratchet.sh compare --old F1 --new F2 [--allow-remove]       CI/PR view: new baseline may only be equal or lower
#
# Baseline file (convention: <repo>/.afx/ratchet-baseline.json), one entry per package ("scope"):
#   { "version": 1, "scopes": { "<scope>": { "dir": "artifacts/api-server", "keyMode": "full"|"loose",
#       "tsc":   { "cmd": "...", "total": N, "errors": { "<file>|<TSxxxx>|<message>": count } },
#       "tests": { "cmd": "...", "failing": [ "<test name>", ... ] } } } }
#   tsc keys ignore line and column numbers (they drift); "loose" keys on file|code only. TS6305 (project reference noise)
#   is excluded, as in afx-digest.mjs. A section (tsc / tests) is only ratcheted when the baseline has it.
#   Test names are read from TAP "not ok", vitest "FAIL" lines, jest "●" lines or "x" marks (first style found wins).
#
# Exit codes: 0 no regression (or no baseline: SKIP), 1 regression, 2 usage / bad file, 4 a command failed without producing a
#   parseable result (a crashed tsc must never look like a green one), 5 compare: the new baseline is higher than the old,
#   6 the dependency install a scope needed failed (an environment problem, never reported as "new failing tests").
# Dependencies (2026-10-15): before a scope's commands run (`run`, and `record --tsc-cmd/--tests-cmd`), when the scope's directory has
#   its own package.json AND its own lockfile but no node_modules (a nested app in a fresh worktree: a mobile
#   app next to a web app), it is installed first with the lockfile frozen: pnpm-lock.yaml -> `pnpm install --frozen-lockfile`,
#   package-lock.json -> `npm ci`. The install goes through afx-gate-run.sh (the 3-slot lock) unless this process already runs inside a
#   gate slot (AFX_IN_GATE_SLOT=1, exported by afx-gate-run.sh). One install per directory per run. AFX_RATCHET_NO_INSTALL=1 disables it.
#   Overrides for tests: AFX_RATCHET_GATE_RUN=<gate wrapper script>.
# Base comparison (2026-10-15): a command that crashes, or a new error/failing test, is re-run on origin/<base> (AFX_RATCHET_BASE_REF) in a
#   throwaway worktree sharing this checkout's node_modules. What also fails there is printed as PRE-EXISTING and is not new; a crash
#   that happens only on the branch is still exit 4, a failure the base does not have is still exit 1. AFX_RATCHET_NO_BASE=1 disables it.
#   The base run sets pnpm's verify-deps-before-run off (2026-10-15): pnpm 11+ otherwise tries to install into the symlinked tree and
#   dies before any test runs, which made every failure that also exists on the base look new.
# `record` creates a scope; replacing an existing scope needs --force and prints RAISED when the baseline goes up (an owner-visible act).
# `run` executes each scope's stored commands with bash -c in <repo root>/<dir> (the repo root is the baseline file's parent's parent).
# --lower: only when nothing regressed and something improved, rewrite the baseline file in place (min of old and current).
set -u
case "${1:-}" in -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0;; esac
PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi; done
[ -z "$PY" ] && { echo "afx-ratchet: python is needed" >&2; exit 2; }
AFX_RATCHET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"; export AFX_RATCHET_DIR
exec "$PY" - "$@" <<'PYEOF'
import atexit, json, os, re, shutil, subprocess, sys, tempfile

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TSC_A = re.compile(r"(?:^|\s)([^\s()]+)\((\d+),(\d+)\): error (TS\d+): (.*)$")
TSC_B = re.compile(r"(?:^|\s)([^\s()]+):(\d+):(\d+) - error (TS\d+): (.*)$")
TIMING = re.compile(r"\s+\(?\d+(?:\.\d+)?\s?m?s\)?$")

def die(code, msg):
    sys.stderr.write("afx-ratchet: %s\n" % msg); sys.exit(code)

def norm_path(p):
    p = p.replace("\\", "/")
    cwd = os.getcwd().replace("\\", "/").rstrip("/") + "/"
    if p.startswith(cwd): p = p[len(cwd):]
    while p.startswith("./"): p = p[2:]
    return p

def parse_tsc(text, loose):
    errs = {}
    for raw in text.splitlines():
        line = ANSI.sub("", raw).rstrip()
        m = TSC_A.search(line) or TSC_B.search(line)
        if not m: continue
        f, code, msg = norm_path(m.group(1)), m.group(4), m.group(5).strip()[:200]
        if code == "TS6305": continue
        key = "%s|%s" % (f, code) if loose else "%s|%s|%s" % (f, code, msg)
        errs[key] = errs.get(key, 0) + 1
    return errs

# Checkout roots whose absolute prefix is stripped from test names. node:test names a suite that fails at import by its ABSOLUTE FILE PATH
# ("not ok 3 - /Users/me/wt-a/artifacts/api-server/src/x.test.ts"), so the same failure on the base worktree (another directory) had another
# name and was reported NEW although origin/main fails identically (2026-10-15: 3 suites failing without DATABASE_URL).
_STRIP = []
def note_root(p):
    for q in {p, os.path.realpath(p), "/private" + p if p.startswith(("/var/", "/tmp/")) else p}:
        q = q.rstrip("/")
        if q and q not in _STRIP: _STRIP.append(q)
    _STRIP.sort(key=len, reverse=True)

def strip_roots(line):
    for r in _STRIP:
        if r in line: line = line.replace(r + "/", "").replace(r, ".")
    return line

def parse_tests(text):
    tap, fail, jest, mark = set(), set(), set(), set()
    for raw in text.splitlines():
        line = strip_roots(ANSI.sub("", raw).rstrip())
        m = re.match(r"^\s*not ok \d+ - (.*)$", line)
        if m:
            if re.search(r"#\s*(SKIP|TODO)\b", m.group(1), re.I): continue
            tap.add(re.sub(r"\s+#.*$", "", m.group(1)).strip()); continue
        m = re.match(r"^\s*FAIL\s+(\S.*)$", line)
        if m: fail.add(TIMING.sub("", m.group(1)).strip()); continue
        m = re.match(r"^\s*●\s+(\S.*)$", line)
        if m and "›" in m.group(1): jest.add(m.group(1).strip()); continue
        m = re.match(r"^\s*[×✗✕✖]\s+(\S.*)$", line)
        if m and not re.match(r"^(failing tests|failed tests?)\b", m.group(1), re.I): mark.add(TIMING.sub("", m.group(1)).strip())
    for s in (tap, fail, jest, mark):
        if s: return sorted(s)
    return []

def load(path):
    try:
        with open(path, encoding="utf-8") as fh: d = json.load(fh)
    except (OSError, ValueError) as e:
        die(2, "cannot read baseline %s: %s" % (path, e))
    if not isinstance(d, dict) or not isinstance(d.get("scopes"), dict): die(2, "baseline %s has no 'scopes' object" % path)
    return d

def save(path, d):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(d, sort_keys=True, indent=1) + "\n")

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh: return fh.read()
    except OSError as e: die(2, "cannot read log %s: %s" % (path, e))

def repo_root(baseline):
    return os.path.dirname(os.path.dirname(os.path.abspath(baseline)))

def run_cmd(cmd, cwd):
    p = subprocess.run(["bash", "-c", cmd], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


# Same-environment baseline (2026-10-15). The stored baseline was recorded somewhere else (a Replit workspace with a database URL,
# installs, built libraries); a fresh worktree on this Mac often cannot run the same commands, so every row read new=0 yet the run
# FAILED (crashed commands, suites that fail at import without DATABASE_URL). Whenever the branch run looks bad, the SAME command is run
# on origin/<base> in a throwaway worktree that shares this checkout's node_modules and environment: what fails there too is
# "pre-existing" in this environment, and only what the base does not fail counts as new. Real new failures still fail.
# AFX_RATCHET_BASE_REF overrides the ref (afx-land.sh exports origin/<base>); AFX_RATCHET_NO_BASE=1 turns this off.
_base = {"tried": False, "dir": None, "root": None, "ref": None}

def base_ref(root):
    if os.environ.get("AFX_RATCHET_NO_BASE") == "1": return None
    ref = os.environ.get("AFX_RATCHET_BASE_REF")
    for c in ([ref] if ref else ["origin/main", "origin/master"]):
        p = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "-q", c + "^{commit}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode == 0: return c
    return None

def base_tree(root):
    """Lazily create a detached worktree of the base ref, with every node_modules of this checkout linked in. None if impossible."""
    if _base["tried"]: return _base["dir"]
    _base["tried"] = True
    ref = base_ref(root)
    if not ref: return None
    tmp = tempfile.mkdtemp(prefix="afx-ratchet-base-"); wt = os.path.join(tmp, "wt")
    p = subprocess.run(["git", "-C", root, "worktree", "add", "--detach", "-q", wt, ref], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True); return None
    _base.update(dir=wt, root=root, ref=ref, tmp=tmp)
    note_root(wt); note_root(root)
    for dp, dns, _ in os.walk(root):
        rel = os.path.relpath(dp, root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        dns[:] = [d for d in dns if d not in (".git", ".claude", ".pnpm") and not (d == "node_modules" and not link_nm(root, wt, rel, d))]
        if depth >= 4: dns[:] = []
    atexit.register(base_cleanup)
    return wt

def link_nm(root, wt, rel, name):
    dst_parent = wt if rel == "." else os.path.join(wt, rel)
    if not os.path.isdir(dst_parent): return False
    dst = os.path.join(dst_parent, name)
    if not os.path.lexists(dst):
        try: os.symlink(os.path.join(root, rel, name) if rel != "." else os.path.join(root, name), dst)
        except OSError: pass
    return False  # never descend into node_modules

def base_cleanup():
    if _base.get("dir"):
        subprocess.run(["git", "-C", _base["root"], "worktree", "remove", "--force", _base["dir"]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        shutil.rmtree(_base.get("tmp", _base["dir"]), ignore_errors=True)
        subprocess.run(["git", "-C", _base["root"], "worktree", "prune"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        _base["dir"] = None

def base_run(root, scope_dir, cmd):
    """Run cmd on the base ref; returns (rc, text, ref) or None when no base tree can be made."""
    wt = base_tree(root)
    if wt is None: return None
    cwd = os.path.join(wt, scope_dir)
    if not os.path.isdir(cwd): return None
    # pnpm 11+ re-verifies dependencies before every script and tries to install. This tree's node_modules are symlinks to
    # the checkout's, which pnpm refuses ("workspace hoist directory is not a real directory"): the tests then never ran,
    # nothing could be compared, and every failure that also exists on the base read as NEW. The base tree is a read-only
    # mirror: never let pnpm install into it.
    keys = ("npm_config_verify_deps_before_run", "pnpm_config_verify_deps_before_run")
    saved = {k: os.environ.get(k) for k in keys}
    for k in keys: os.environ[k] = "false"
    try:
        rc, text = run_cmd(cmd, cwd)
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
    return rc, text, _base["ref"]

REPLIT_MIRROR = "http://package-firewall.replit.local/npm/"
_installed = set()

def ensure_deps(name, cwd):
    """Install a scope's own dependencies (frozen) when it has package.json + its own lockfile but no node_modules.
    Exits 6 with a distinct message when the install fails; returns quietly when nothing needs doing."""
    if os.environ.get("AFX_RATCHET_NO_INSTALL") == "1": return
    cwd = os.path.abspath(cwd)
    if cwd in _installed: return
    if not os.path.isfile(os.path.join(cwd, "package.json")) or os.path.isdir(os.path.join(cwd, "node_modules")): return
    if os.path.isfile(os.path.join(cwd, "pnpm-lock.yaml")):
        cmd, lock = ["pnpm", "install", "--frozen-lockfile"], None
    elif os.path.isfile(os.path.join(cwd, "package-lock.json")):
        cmd, lock = ["npm", "ci", "--no-audit", "--no-fund"], os.path.join(cwd, "package-lock.json")
    else:
        return  # no lockfile of its own: nothing to install frozen (the repo-root install covers workspace members)
    _installed.add(cwd)
    env = dict(os.environ); env["CI"] = "true"
    orig = None
    if lock:
        # Lockfiles written on Replit point at its private mirror, which does not resolve off Replit: install from a
        # temporary public-registry copy and restore the tracked file afterwards (same packages and integrity hashes).
        with open(lock, encoding="utf-8") as fh: txt = fh.read()
        if REPLIT_MIRROR in txt:
            orig = txt
            with open(lock, "w", encoding="utf-8", newline="") as fh: fh.write(txt.replace(REPLIT_MIRROR, "https://registry.npmjs.org/"))
    run = list(cmd)
    if os.environ.get("AFX_IN_GATE_SLOT") != "1":
        gate = os.environ.get("AFX_RATCHET_GATE_RUN") or os.path.join(os.environ.get("AFX_RATCHET_DIR", ""), "afx-gate-run.sh")
        if os.path.isfile(gate):
            env["AFX_GATE_VERBOSE"] = "1"
            run = [gate, cwd, "ratchet-install-%s" % re.sub(r"[^A-Za-z0-9._-]", "_", name), "--"] + cmd
    sys.stderr.write("afx-ratchet: scope %s has no node_modules in %s: installing (%s)\n" % (name, cwd, " ".join(cmd)))
    try:
        p = subprocess.run(run, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        rc, text = p.returncode, p.stdout.decode("utf-8", "replace")
    except OSError as e:
        rc, text = 127, str(e)
    finally:
        if orig is not None:
            with open(lock, "w", encoding="utf-8", newline="") as fh: fh.write(orig)
    if rc != 0:
        print("\n".join(text.rstrip().splitlines()[-12:]))
        print("RATCHET: INSTALL FAILED for scope %s: `%s` exited %d in %s." % (name, " ".join(cmd), rc, cwd))
        print("  This is a dependency/environment problem, not a test or typecheck regression: nothing was compared.")
        sys.exit(6)

def tsc_total(errors): return sum(errors.values())

def check_scope(name, sc, cur_tsc, cur_tests, out):
    """returns (regressed, improved, lowered_scope_or_None)"""
    regressed = improved = False
    low = json.loads(json.dumps(sc))
    if "tsc" in sc and cur_tsc is not None:
        base = sc["tsc"].get("errors", {})
        new = {k: v - base.get(k, 0) for k, v in cur_tsc.items() if v > base.get(k, 0)}
        fixed = sum(max(0, v - cur_tsc.get(k, 0)) for k, v in base.items())
        bt, ct, nn = tsc_total(base), tsc_total(cur_tsc), sum(new.values())
        out.append("tsc   %-28s %d -> %d (%+d)  new=%d fixed=%d" % (name, bt, ct, ct - bt, nn, fixed))
        if nn:
            regressed = True
            for k in sorted(new)[:20]: out.append("  NEW tsc error x%d: %s" % (new[k], k))
            if len(new) > 20: out.append("  ... and %d more new error keys" % (len(new) - 20))
        if fixed: improved = True
        merged = {k: min(v, cur_tsc.get(k, 0)) for k, v in base.items() if min(v, cur_tsc.get(k, 0)) > 0}
        low["tsc"]["errors"] = merged; low["tsc"]["total"] = tsc_total(merged)
    if "tests" in sc and cur_tests is not None:
        base = set(sc["tests"].get("failing", [])); cur = set(cur_tests)
        new, fixed = sorted(cur - base), sorted(base - cur)
        out.append("tests %-28s failing %d -> %d (%+d)  new=%d fixed=%d" % (name, len(base), len(cur), len(cur) - len(base), len(new), len(fixed)))
        if new:
            regressed = True
            for t in new[:20]: out.append("  NEW failing test: %s" % t)
        if fixed: improved = True
        low["tests"]["failing"] = sorted(base & cur)
    return regressed, improved, low

def cmd_check(a, scopes_cur, runner_note=None):
    d = load(a["baseline"]); out = []; reg = imp = False
    new_d = json.loads(json.dumps(d))
    for name, (ct, cte) in scopes_cur.items():
        sc = d["scopes"].get(name)
        if sc is None: out.append("scope %s is not in the baseline: not ratcheted (record it to start)" % name); continue
        r, i, low = check_scope(name, sc, ct, cte, out)
        reg, imp = reg or r, imp or i
        new_d["scopes"][name] = low
    print("\n".join(out))
    if reg:
        print("RATCHET: FAIL (regression: new errors or newly failing tests; fix them, do not raise the baseline)"); return 1
    if imp and a.get("lower"):
        save(a["baseline"], new_d); print("RATCHET: PASS, baseline LOWERED in %s (commit it with the PR)" % a["baseline"])
    elif imp: print("RATCHET: PASS, burn-down available: re-run with --lower to lock it in")
    else: print("RATCHET: PASS (no change)")
    return 0

def parse_args(argv):
    a = {"lower": False, "force": False, "loose": False, "allow-remove": False}
    i = 0
    flags = {"--lower": "lower", "--force": "force", "--loose": "loose", "--allow-remove": "allow-remove"}
    opts = {"--baseline": "baseline", "--scope": "scope", "--dir": "dir", "--tsc-log": "tsc-log", "--tests-log": "tests-log",
            "--tsc-cmd": "tsc-cmd", "--tests-cmd": "tests-cmd", "--old": "old", "--new": "new"}
    while i < len(argv):
        t = argv[i]
        if t in flags: a[flags[t]] = True; i += 1
        elif t in opts:
            if i + 1 >= len(argv): die(2, "%s needs a value" % t)
            a[opts[t]] = argv[i + 1]; i += 2
        else: die(2, "unknown argument %s" % t)
    return a

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: afx-ratchet.sh record|check|run|compare ... (see the header of afx-ratchet.sh)"); return 0 if len(sys.argv) > 1 else 2
    sub, a = sys.argv[1], parse_args(sys.argv[2:])
    if sub == "compare":
        if not a.get("old") or not a.get("new"): die(2, "compare needs --old and --new")
        old, new = load(a["old"]), load(a["new"]); bad = []
        for name, osc in old["scopes"].items():
            nsc = new["scopes"].get(name)
            if nsc is None:
                if not a["allow-remove"]: bad.append("scope %s removed from the baseline (unratcheting is an owner decision)" % name)
                continue
            for sec in ("tsc", "tests"):
                if sec in osc and sec not in nsc and not a["allow-remove"]: bad.append("%s: %s section removed" % (name, sec))
            if "tsc" in osc and "tsc" in nsc:
                ob, nb = osc["tsc"].get("errors", {}), nsc["tsc"].get("errors", {})
                up = sorted(k for k, v in nb.items() if v > ob.get(k, 0))
                if up: bad.append("%s: %d tsc key(s) raised or added, e.g. %s" % (name, len(up), up[0]))
            if "tests" in osc and "tests" in nsc:
                up = sorted(set(nsc["tests"].get("failing", [])) - set(osc["tests"].get("failing", [])))
                if up: bad.append("%s: %d failing test(s) added, e.g. %s" % (name, len(up), up[0]))
        for name in new["scopes"]:
            if name not in old["scopes"]: print("note: scope %s is new in this baseline (initial record)" % name)
        if bad:
            print("RATCHET-COMPARE: FAIL"); [print("  " + b) for b in bad]; return 5
        ot = sum(tsc_total(s.get("tsc", {}).get("errors", {})) for s in old["scopes"].values())
        nt = sum(tsc_total(s.get("tsc", {}).get("errors", {})) for s in new["scopes"].values())
        print("RATCHET-COMPARE: PASS (tsc errors %d -> %d, baseline unchanged or lowered)" % (ot, nt)); return 0
    if not a.get("baseline"): die(2, "--baseline is required")
    if sub == "record":
        name = a.get("scope");
        if not name: die(2, "record needs --scope")
        d = json.load(open(a["baseline"], encoding="utf-8")) if os.path.exists(a["baseline"]) else {"version": 1, "scopes": {}}
        if name in d["scopes"] and not a["force"]: die(2, "scope %s already recorded; use check --lower to lower it or --force to replace (owner-visible)" % name)
        sc = {"dir": a.get("dir", "."), "keyMode": "loose" if a["loose"] else "full"}
        cwd = os.path.join(repo_root(a["baseline"]), sc["dir"])
        for sec, logk, cmdk in (("tsc", "tsc-log", "tsc-cmd"), ("tests", "tests-log", "tests-cmd")):
            if not a.get(logk) and not a.get(cmdk): continue
            if a.get(cmdk):
                ensure_deps(name, cwd)
                rc, text = run_cmd(a[cmdk], cwd)
            else: rc, text = 0, read(a[logk])
            if sec == "tsc":
                errs = parse_tsc(text, a["loose"])
                if rc != 0 and not errs: die(4, "tsc command exited %d with no parseable errors" % rc)
                sc["tsc"] = {"errors": errs, "total": tsc_total(errs)}
            else:
                names = parse_tests(text)
                if rc != 0 and not names: die(4, "test command exited %d with no parseable failing tests (crash, or an unknown reporter?)" % rc)
                sc["tests"] = {"failing": names}
            if a.get(cmdk): sc[sec]["cmd"] = a[cmdk]
        if "tsc" not in sc and "tests" not in sc: die(2, "record needs --tsc-log/--tsc-cmd and/or --tests-log/--tests-cmd")
        old = d["scopes"].get(name)
        if old is not None:
            ot = tsc_total(old.get("tsc", {}).get("errors", {})); nt = sc.get("tsc", {}).get("total", 0)
            if nt > ot or len(sc.get("tests", {}).get("failing", [])) > len(old.get("tests", {}).get("failing", [])): print("RAISED: baseline for %s went UP (owner-visible act)" % name)
        d["scopes"][name] = sc; save(a["baseline"], d)
        print("recorded %s: tsc=%s failing-tests=%s -> %s" % (name, sc.get("tsc", {}).get("total", "-"), len(sc["tests"]["failing"]) if "tests" in sc else "-", a["baseline"]))
        return 0
    if not os.path.exists(a["baseline"]):
        print("afx-ratchet: SKIP, no baseline at %s (nothing to ratchet)" % a["baseline"]); return 0
    d = load(a["baseline"])
    if sub == "check":
        name = a.get("scope")
        if not name: die(2, "check needs --scope")
        sc = d["scopes"].get(name)
        if sc is None: print("afx-ratchet: SKIP, scope %s not in the baseline" % name); return 0
        loose = sc.get("keyMode") == "loose"
        ct = parse_tsc(read(a["tsc-log"]), loose) if a.get("tsc-log") else None
        cte = parse_tests(read(a["tests-log"])) if a.get("tests-log") else None
        if ct is None and cte is None: die(2, "check needs --tsc-log and/or --tests-log")
        return cmd_check(a, {name: (ct, cte)})
    if sub == "run":
        cur = {}; root = repo_root(a["baseline"]); note_root(root)
        for name, sc in sorted(d["scopes"].items()):
            if a.get("scope") and name != a["scope"]: continue
            sdir = sc.get("dir", "."); cwd = os.path.join(root, sdir)
            loose = sc.get("keyMode") == "loose"
            if "tsc" in sc or "tests" in sc: ensure_deps(name, cwd)
            ct = cte = None
            if "tsc" in sc:
                if not sc["tsc"].get("cmd"): die(2, "scope %s has no stored tsc cmd; use check with --tsc-log" % name)
                cmd = sc["tsc"]["cmd"]; rc, text = run_cmd(cmd, cwd); ct = parse_tsc(text, loose)
                if rc != 0 and not ct:
                    br = base_run(root, sdir, cmd)
                    if br is not None and br[0] != 0 and not parse_tsc(br[1], loose):
                        print("PRE-EXISTING: scope %s: the tsc command crashes the same way (exit %d, nothing parseable) on %s in this environment: not compared" % (name, rc, br[2])); ct = None
                    else:
                        sys.stderr.write(text[-2000:]); die(4, "scope %s: tsc command exited %d with no parseable errors" % (name, rc))
                elif ct:
                    base_errs = sc["tsc"].get("errors", {})
                    if any(v > base_errs.get(k, 0) for k, v in ct.items()):
                        br = base_run(root, sdir, cmd)
                        if br is not None:
                            on_base = parse_tsc(br[1], loose); pre = 0
                            for k, v in list(ct.items()):
                                allowed = max(base_errs.get(k, 0), on_base.get(k, 0))
                                if v > allowed: continue
                                if v > base_errs.get(k, 0): pre += v - base_errs.get(k, 0); ct[k] = base_errs.get(k, 0) if base_errs.get(k, 0) else None
                            ct = {k: v for k, v in ct.items() if v}
                            if pre: print("PRE-EXISTING: scope %s: %d tsc error(s) not in the baseline file also occur on %s in this environment: not counted as new" % (name, pre, br[2]))
            if "tests" in sc:
                if not sc["tests"].get("cmd"): die(2, "scope %s has no stored tests cmd; use check with --tests-log" % name)
                cmd = sc["tests"]["cmd"]; rc, text = run_cmd(cmd, cwd); cte = parse_tests(text)
                if rc != 0 and not cte:
                    br = base_run(root, sdir, cmd)
                    if br is not None and br[0] != 0 and not parse_tests(br[1]):
                        print("PRE-EXISTING: scope %s: the test command crashes the same way (exit %d, nothing parseable) on %s in this environment: not compared" % (name, rc, br[2])); cte = None
                    else:
                        sys.stderr.write(text[-2000:]); die(4, "scope %s: test command exited %d with no parseable failing tests" % (name, rc))
                elif cte:
                    base_fail = set(sc["tests"].get("failing", []))
                    if any(t not in base_fail for t in cte):
                        br = base_run(root, sdir, cmd)
                        if br is not None:
                            on_base = set(parse_tests(br[1]))
                            pre = [t for t in cte if t not in base_fail and t in on_base]
                            if pre:
                                print("PRE-EXISTING: scope %s: %d failing test(s) not in the baseline file also fail on %s in this environment: not counted as new" % (name, len(pre), br[2]))
                                cte = [t for t in cte if t not in pre]
            cur[name] = (ct, cte)
        if not cur: die(2, "no matching scope to run")
        if all(ct is None and cte is None for ct, cte in cur.values()):
            print("RATCHET: PASS (nothing could be compared in this environment: every command crashes the same way on the base ref)"); return 0
        return cmd_check(a, cur)
    die(2, "unknown command %s" % sub)

sys.exit(main())
PYEOF
