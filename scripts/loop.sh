#!/usr/bin/env bash
#
# loop.sh — the acceptance-gated build loop behind `bones build` (the auto gate).
#
# bones.sh (bones build) invokes this as:
#   loop.sh -t <target> -c "<acceptance_cmd>" -s <spec> [-r <rubric>] [-R auto|codex|gemini] [-n <max>]
#
# Contract with bones: this script EXITS 0 iff the acceptance command exits 0.
# Only that opens the auto gate. Any other exit keeps the gate closed,
# so the agent fixes the code and re-runs `bones build`.
#
# The "loop": if a reviewer CLI (-R codex|gemini) is available on PATH, loop.sh
# will, between failed acceptance runs, hand the failure + spec/rubric to that
# reviewer to attempt a fix, then re-check — up to -n iterations. With no
# reviewer available it runs the check once and reports honestly (the human/agent
# is the fixer between `bones build` calls).
#
set -uo pipefail

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf 'loop: %s\n' "$1"; }
die() { printf 'loop: %s\n' "$1" >&2; exit 2; }

target="$PWD" accept="" spec="" rubric="" reviewer="auto" maxn=""
while getopts ":t:c:s:r:R:n:" o; do case "$o" in
  t) target="$OPTARG" ;;
  c) accept="$OPTARG" ;;
  s) spec="$OPTARG" ;;
  r) rubric="$OPTARG" ;;
  R) reviewer="$OPTARG" ;;
  n) maxn="$OPTARG" ;;
  :) die "-$OPTARG needs an argument" ;;
  \?) die "unknown flag -$OPTARG" ;;
esac; done

[ -n "$accept" ] || die "no acceptance command — pass -c \"<cmd>\" (bones build -c ...). The gate needs something executable to verify."
[ -d "$target" ] || die "target dir not found: $target"
cd "$target" || die "cannot cd into target: $target"

# Resolve the reviewer CLI (only if the user asked for a real one and it exists).
reviewer_cli=""
case "$reviewer" in
  codex)  command -v codex  >/dev/null 2>&1 && reviewer_cli="codex"  ;;
  gemini) command -v gemini >/dev/null 2>&1 && reviewer_cli="gemini" ;;
  auto)   for c in codex gemini; do command -v "$c" >/dev/null 2>&1 && { reviewer_cli="$c"; break; }; done ;;
  none|"") reviewer_cli="" ;;
  *) die "unknown reviewer '$reviewer' (use auto|codex|gemini|none)" ;;
esac

# Default iteration budget: 1 with no reviewer (nothing here can fix code),
# a few when a reviewer CLI can actually attempt fixes.
[ -n "$maxn" ] || { [ -n "$reviewer_cli" ] && maxn=6 || maxn=1; }

printf '== bones build loop ==\n target : %s\n accept : %s\n spec   : %s\n rubric : %s\n review : %s\n budget : %s iteration(s)\n\n' \
  "$target" "$accept" "${spec:-<none>}" "${rubric:-<none>}" "${reviewer_cli:-none available}" "$maxn"

run_accept() { # streams output, returns the command's exit code
  say "[$(now)] running acceptance: $accept"
  bash -c "$accept"
}

i=1
while :; do
  printf '\n-- iteration %s/%s --\n' "$i" "$maxn"
  run_accept
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '\nloop: ACCEPTANCE PASSED (exit 0) on iteration %s. Gate may open.\n' "$i"
    exit 0
  fi
  say "acceptance failed (exit $rc)"

  if [ "$i" -ge "$maxn" ]; then
    printf '\nloop: budget exhausted (%s iteration(s)); acceptance still failing.\n' "$maxn"
    printf 'loop: gate stays CLOSED. Fix the code, then re-run `bones build`.\n'
    exit "$rc"
  fi

  if [ -n "$reviewer_cli" ]; then
    say "handing failure to reviewer '$reviewer_cli' to attempt a fix…"
    prompt="The acceptance check for this project failed (exit $rc). Command: $accept."
    [ -n "$spec" ]   && [ -f "$spec" ]   && prompt="$prompt Spec: $spec."
    [ -n "$rubric" ] && [ -f "$rubric" ] && prompt="$prompt Rubric: $rubric."
    prompt="$prompt Read the failure, edit the code in $target to make the acceptance command pass, and stop."
    # Best-effort, non-fatal: if the reviewer errors we just re-loop and report.
    # Run the reviewer NON-interactively (a TUI would hang the gate waiting for input).
    case "$reviewer_cli" in
      codex)  codex exec "$prompt" ;;
      gemini) gemini -p "$prompt" ;;
    esac || say "reviewer '$reviewer_cli' returned non-zero; re-checking anyway"
  else
    printf '\nloop: no reviewer CLI available — nothing here can edit code.\n'
    printf 'loop: gate stays CLOSED. Fix the code, then re-run `bones build`.\n'
    exit "$rc"
  fi
  i=$((i+1))
done
