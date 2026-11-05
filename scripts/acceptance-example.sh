#!/usr/bin/env bash
#
# acceptance-example.sh — a STARTER acceptance command for the bones AUTO gate (stage 5).
#
# The build gate passes only when its acceptance command exits 0:
#     bones build -c "./check.sh"      (loop.sh runs it; exit 0 = gate opens)
#
# A static HTML/CSS/JS deliverable often ships with NO test harness, so there is
# nothing native for the gate to run. Copy this into your target
# as `check.sh`, make it executable, and adapt the checks to what "done" means for
# THIS slice. Keep it fast and deterministic — it is the machine's definition of done.
#
# It is deliberately dependency-light: pure shell + grep, with an optional upgrade to
# a real HTML validator if one is installed. Exit non-zero on the first failure.
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

fail() { printf 'CHECK FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'CHECK ok: %s\n' "$1"; }

# ── 1. Required files exist ────────────────────────────────────────────────
# Adapt this list to the files your slice must produce/touch.
REQUIRED=(index.html)
for f in "${REQUIRED[@]}"; do
  [ -f "$f" ] || fail "required file missing: $f"
done
ok "required files present"

# ── 2. HTML is well-formed ─────────────────────────────────────────────────
# Prefer a real validator when available; otherwise a cheap balance heuristic.
if command -v tidy >/dev/null 2>&1; then
  for f in *.html; do
    [ -e "$f" ] || continue
    tidy -qe "$f" >/dev/null 2>&1 || fail "tidy reported errors in $f"
  done
  ok "HTML validated with tidy"
elif command -v node >/dev/null 2>&1; then
  # node is present but no validator lib assumed — do the cheap structural check below.
  :
fi
for f in *.html; do
  [ -e "$f" ] || continue
  # crude but catches gross breakage: every <script> has a </script>, etc.
  o="$(grep -oc '<script' "$f" || true)"; c="$(grep -oc '</script>' "$f" || true)"
  [ "${o:-0}" = "${c:-0}" ] || fail "$f: unbalanced <script> tags ($o open / $c close)"
done
ok "HTML structural sanity"

# ── 3. Slice-specific acceptance (THE important part — edit me) ─────────────
# Assert the concrete thing this slice is supposed to deliver. Examples:
#   grep -q 'data-period="7j"'  growth.html || fail "period selector 7j not wired"
#   grep -q 'G.countUp'         growth.js   || fail "count-up animation missing"
#   grep -q 'prefers-color-scheme' growth.css || fail "dark-mode tokens missing"
# Leave at least one real assertion here — an empty acceptance gate proves nothing.
: # <-- replace with your assertions

printf 'ACCEPTANCE PASSED\n'
exit 0
