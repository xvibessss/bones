#!/usr/bin/env bash
#
# test.sh — regression suite for bones.sh.
# Fast, self-contained: each test builds a throwaway pipeline in a temp dir.
# Run:  bash test.sh   (exit 0 = all green)
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BONES="$HERE/bones.sh"
# loop.sh ships beside this script in the repo; let bones auto-discover it
# (this just makes the default explicit and keeps the suite hermetic).
export BONES_LOOP_SH="${BONES_LOOP_SH:-$HERE/loop.sh}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
b()   { bash "$BONES" "$@"; }

# helper: build a repo + pipeline advanced through stage N (default: to stage 5 pre-build)
scaffold() { # scaffold <dir>
  local T="$1"
  ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm init >/dev/null )
  b init -t "$T" -n reg >/dev/null
  ( cd "$T" || exit
    b approve "brief interrogated, scope + non-goals pinned" >/dev/null && b next >/dev/null
    b approve -q "commit it" "kill-or-commit cleared" >/dev/null && b next >/dev/null
    echo "<html>spec</html>">spec.html
    b approve -q "spec signed" -e spec.html "spec v1 accepted" >/dev/null && b next >/dev/null
    b approve "council: no blocking objections" >/dev/null && b next >/dev/null
  )
}

printf '\n== bones regression suite ==\n\n'

# ---- 1. happy path: full pipeline advances and completes ----
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" || exit
  b build -c "true" -s spec.html >/dev/null 2>&1 && b next >/dev/null   # 5->6
  b approve "review clean; security N/A" >/dev/null && b next >/dev/null  # 6->7
  b approve "staging e2e green" >/dev/null && b next >/dev/null            # 7->8
  b approve -q "ship to prod" "promoted; smoke green" >/dev/null && b next >/dev/null # 8->9
  b next >/dev/null                                                       # 9 (step) ->10
  b approve -q "double down" "operate: keep it" >/dev/null && b next >/dev/null # 10 done
)
# capture-then-match: piping into `grep -q` under `set -o pipefail` yields the
# producer's SIGPIPE (141), not grep's match status — a false negative.
hp_status="$( cd "$T" && bash "$BONES" status )"
case "$hp_status" in
  *"ALL STAGES COMPLETE"*) ok "happy path: 10 stages complete" ;;
  *) no "happy path did not complete" "$(printf '%s' "$hp_status" | grep -oE 'stage: [0-9]+/10')" ;;
esac
( cd "$T" && bash "$BONES" verify >/dev/null 2>&1 ) && ok "happy path: chain verifies" || no "happy path chain failed verify"
rm -rf "$T"

# ---- 2. gate refusals ----
T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
b init -t "$T" -n ref >/dev/null
( cd "$T" && bash "$BONES" next >/dev/null 2>&1 ) && no "next advanced past unsatisfied agent gate" || ok "next refuses unsatisfied gate"
( cd "$T" && bash "$BONES" approve "x" >/dev/null && bash "$BONES" next >/dev/null )   # ->2 owner
( cd "$T" && bash "$BONES" approve "no quote here" >/dev/null 2>&1 ) && no "owner gate accepted without -q quote" || ok "owner gate demands verbatim quote"
( cd "$T" && bash "$BONES" approve -q "" "empty quote" >/dev/null 2>&1 ) && no "owner gate accepted empty quote" || ok "owner gate rejects empty quote"
( cd "$T" && bash "$BONES" approve -q "go" "ok" >/dev/null 2>&1 ) && no "thin note accepted" || ok "thin note rejected"
rm -rf "$T"

# ---- 3. build gate is machine-only ----
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" && bash "$BONES" approve "trying to sign the build gate" >/dev/null 2>&1 ) && no "approve worked on auto gate" || ok "auto gate rejects approve"
( cd "$T" && bash "$BONES" build -c "false" -s spec.html >/dev/null 2>&1 ) && no "build gate opened on failing check" || ok "build gate stays closed on non-zero acceptance"
( cd "$T" && bash "$BONES" next >/dev/null 2>&1 ) && no "advanced past unverified build" || ok "next refuses unverified build gate"
rm -rf "$T"

# ---- 4. tamper detection (the 6 attacks) ----
mkchain() { # build clean chain through stage 3, echo dir
  local T; T="$(mktemp -d)"
  ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
  b init -t "$T" -n atk >/dev/null
  ( cd "$T" || exit
    b approve "scope pinned" >/dev/null && b next >/dev/null
    b approve -q "go" "committed" >/dev/null && b next >/dev/null
    echo spec>spec.html && b approve -q "ok" -e spec.html "spec signed" >/dev/null )
  printf '%s' "$T"
}
V() { ( cd "$1" && bash "$BONES" verify >/dev/null 2>&1 ); }   # rc 0 = verified

T="$(mkchain)"; V "$T" && ok "baseline chain verifies" || no "baseline failed"; rm -rf "$T"
T="$(mkchain)"; touch "$T/.bones/gates/8-promote.ok";  V "$T" && no "forged gate file not caught" || ok "attack: forged gate file caught"; rm -rf "$T"
T="$(mkchain)"; perl -pi -e 's/spec signed/HACKED/' "$T/.bones/gates/3-spec.ok"; V "$T" && no "edited gate file not caught" || ok "attack: edited gate file caught"; rm -rf "$T"
T="$(mkchain)"; perl -pi -e 's/\|approve\|/|APPROVE|/ if $.==2' "$T/.bones/ledger"; V "$T" && no "ledger field edit not caught" || ok "attack: ledger field edit caught"; rm -rf "$T"
T="$(mkchain)"; sed -i.bak '3d' "$T/.bones/ledger" 2>/dev/null || sed -i '' '3d' "$T/.bones/ledger"; V "$T" && no "deleted link not caught" || ok "attack: deleted middle link caught"; rm -rf "$T"
T="$(mkchain)"; sed -i.bak '$d' "$T/.bones/ledger" 2>/dev/null || sed -i '' '$d' "$T/.bones/ledger"; V "$T" && no "truncation not caught" || ok "attack: truncated tail caught"; rm -rf "$T"

# ---- 5. back + redo keeps verifying ----
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" || exit
  bash "$BONES" back -s 3 -r "council reopened the spec" >/dev/null
  echo spec2>spec.html; bash "$BONES" approve -q "spec v2 ok" -e spec.html "reworked spec" >/dev/null )
V "$T" && ok "back+redo: chain still verifies" || no "back+redo broke verify"
rm -rf "$T"

# ---- 6. concurrency: parallel mutations don't corrupt state or double-advance ----
T="$(mktemp -d)"; scaffold "$T"    # at stage 5, build gate satisfiable
( cd "$T" && bash "$BONES" build -c "true" -s spec.html >/dev/null 2>&1 )
# fire two `next` at once from stage 5 — exactly one should win the advance to 6
( cd "$T" && bash "$BONES" next >/dev/null 2>&1 ) &
( cd "$T" && bash "$BONES" next >/dev/null 2>&1 ) &
wait
conc_stage="$( cd "$T" && bash "$BONES" status )"
case "$conc_stage" in
  *"stage: 6/10"*|*"stage: 7/10"*) ok "concurrency: no corruption, advanced cleanly" ;;
  *) no "concurrency: unexpected state" "$(printf '%s' "$conc_stage" | grep -oE 'stage: [0-9]+/10')" ;;
esac
( cd "$T" && bash "$BONES" verify >/dev/null 2>&1 ) && ok "concurrency: chain intact after race" || no "concurrency corrupted the chain"
[ -d "$T/.bones/.lock" ] && no "lock left dangling after commands" || ok "lock released after each command"
rm -rf "$T"

# ---- 7. templates: ops pipeline loads + build works at its auto stage ----
T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
b init -t "$T" -T ops >/dev/null 2>&1
ops_titles="$( cd "$T" && bash "$BONES" status )"
case "$ops_titles" in *"Produce (acceptance check)"*) ok "template ops: stages loaded" ;; *) no "template ops: stages not loaded" ;; esac
( cd "$T" || exit
  b approve "brief pinned" >/dev/null && b next >/dev/null
  b approve -q "go" "committed" >/dev/null && b next >/dev/null
  echo plan>plan.md && b approve -q "plan ok" -e plan.md "plan signed" >/dev/null && b next >/dev/null
  b approve "critique done" >/dev/null && b next >/dev/null            # ->5 produce (auto)
)
( cd "$T" && bash "$BONES" build -c "true" >/dev/null 2>&1 ) && ok "template ops: build works at non-default auto stage" || no "template ops: build failed at auto stage"
( cd "$T" && bash "$BONES" verify >/dev/null 2>&1 ) && ok "template ops: chain verifies" || no "template ops: verify failed"
rm -rf "$T"

# ---- 8. config: owner override reaches gate messages ----
T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
b init -t "$T" >/dev/null
( cd "$T" && bash "$BONES" approve "scope" >/dev/null && bash "$BONES" next >/dev/null )   # ->2 owner
owner_msg="$( cd "$T" && BONES_OWNER='Robin' bash "$BONES" status )"
case "$owner_msg" in *"ROBIN'S call"*) ok "config: owner override reaches messages" ;; *) no "config: owner override missing" ;; esac
rm -rf "$T"

# ---- 9. GPG signing (skipped cleanly when gpg is unavailable) ----
if command -v gpg >/dev/null 2>&1; then
  GH="$(mktemp -d)"; chmod 700 "$GH"
  if GNUPGHOME="$GH" gpg --batch --pinentry-mode loopback --passphrase '' \
       --quick-generate-key "Bones Test <bones@test>" ed25519 sign 0 >/dev/null 2>&1; then
    T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
    GNUPGHOME="$GH" BONES_SIGN=1 bash "$BONES" init -t "$T" >/dev/null 2>&1
    ( cd "$T" && GNUPGHOME="$GH" BONES_SIGN=1 bash "$BONES" approve "scope" >/dev/null && GNUPGHOME="$GH" BONES_SIGN=1 bash "$BONES" next >/dev/null )
    ( cd "$T" && GNUPGHOME="$GH" BONES_SIGN=1 bash "$BONES" approve -q "ship it" "committed" >/dev/null 2>&1 )
    ls "$T"/.bones/sigs/*.asc >/dev/null 2>&1 && ok "signing: owner gate produced a signature" || no "signing: no signature file"
    ( cd "$T" && GNUPGHOME="$GH" bash "$BONES" verify >/dev/null 2>&1 ) && ok "signing: signed chain verifies" || no "signing: valid sig rejected"
    # tamper the signature → verify must fail. Corrupt the first base64 line of
    # the armored body: appending after the END line is not a tamper, gpg
    # ignores trailing data and the signature still verifies.
    perl -pi -e 'if ($body && !$done && /^[A-Za-z0-9+\/]{8}/) { s/^(.)/$1 eq "A" ? "B" : "A"/e; $done = 1 } $body = 1 if /^\s*$/' "$T"/.bones/sigs/*.asc
    ( cd "$T" && GNUPGHOME="$GH" bash "$BONES" verify >/dev/null 2>&1 ) && no "signing: tampered sig not caught" || ok "signing: tampered signature caught"
    rm -rf "$T"
  else printf '  \033[33m•\033[0m signing: gpg present but ephemeral keygen failed — skipped\n'; fi
  rm -rf "$GH"
else printf '  \033[33m•\033[0m signing: gpg not installed — skipped\n'; fi

# ---- 10. kill: owner stops the build (terminal, distinct from an open gate) ----
T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
b init -t "$T" -n killreg >/dev/null
( cd "$T" && bash "$BONES" approve "scope pinned" >/dev/null && bash "$BONES" next >/dev/null )   # ->2 owner kill-or-commit
( cd "$T" && bash "$BONES" kill -r "no quote" >/dev/null 2>&1 ) && no "kill accepted without -q quote" || ok "kill demands verbatim quote"
( cd "$T" && bash "$BONES" kill -q "stop it" >/dev/null 2>&1 ) && no "kill accepted without -r reason" || ok "kill demands a reason"
( cd "$T" && bash "$BONES" kill -q "kill le build" -r "not worth it" >/dev/null 2>&1 ) && ok "kill records the stop" || no "kill failed on valid input"
kstat="$( cd "$T" && bash "$BONES" status )"
case "$kstat" in *"KILLED"*) ok "status shows KILLED" ;; *) no "status does not show KILLED" ;; esac
( cd "$T" && bash "$BONES" next    >/dev/null 2>&1 ) && no "next advanced a killed pipeline"    || ok "next refuses on killed"
( cd "$T" && bash "$BONES" approve -q "x" "y z" >/dev/null 2>&1 ) && no "approve worked on killed" || ok "approve refuses on killed"
( cd "$T" && bash "$BONES" build -c "true" >/dev/null 2>&1 ) && no "build ran on killed"         || ok "build refuses on killed"
( cd "$T" && bash "$BONES" verify  >/dev/null 2>&1 ) && ok "killed chain still verifies" || no "killed chain failed verify"
# tamper the kill record → verify must fail, then restore exact bytes from a backup
cp "$T"/.bones/killed.ok "$T/.killed.bak"
echo "sneaky" >> "$T"/.bones/killed.ok
( cd "$T" && bash "$BONES" verify >/dev/null 2>&1 ) && no "tampered killed.ok not caught" || ok "tampered killed.ok caught"
cp "$T/.killed.bak" "$T"/.bones/killed.ok
# revive via back
( cd "$T" && bash "$BONES" back -s 1 -r "owner reversed" >/dev/null 2>&1 )
rstat="$( cd "$T" && bash "$BONES" status )"
case "$rstat" in *"KILLED"*) no "revive left it killed" ;; *"stage: 1/"*) ok "back revives a killed pipeline" ;; *) no "revive landed in an unexpected state" ;; esac
( cd "$T" && bash "$BONES" verify >/dev/null 2>&1 ) && ok "revived chain verifies" || no "revived chain failed verify"
rm -rf "$T"

# ---- 11. non-git target: init warns (F2), verify flags UNANCHORED (F6) ----
T="$(mktemp -d)"   # NOT a git repo
init_out="$( bash "$BONES" init -t "$T" -n nogit 2>&1 )"
case "$init_out" in *"NOT a git repository"*) ok "init warns on non-git target" ;; *) no "init did not warn on non-git target" ;; esac
( cd "$T" && bash "$BONES" approve "scope pinned real note" >/dev/null )
vout="$( cd "$T" && bash "$BONES" verify 2>&1 )"
case "$vout" in *"UNANCHORED"*) ok "verify flags an unanchored (no-git) chain" ;; *) no "verify did not flag unanchored chain" ;; esac
rm -rf "$T"

# ---- 12. state & archive attacks: what the chain itself must refuse ----
# Skipping stages by editing state.json (no gate record for the skipped stages).
T="$(mkchain)"; ( cd "$T" && b next >/dev/null )                 # legit: now at stage 4
perl -pi -e 's/"stage": 4/"stage": 9/' "$T/.bones/state.json"
V "$T" && no "stage skip via state.json not caught" || ok "attack: stages skipped by editing state.json caught"; rm -rf "$T"
# Deleting the gate record of a stage already passed.
T="$(mkchain)"; ( cd "$T" && b next >/dev/null ); rm "$T/.bones/gates/2-kill-or-commit.ok"
V "$T" && no "deleted passed gate not caught" || ok "attack: deleted record of a passed gate caught"; rm -rf "$T"
# Resurrecting a gate revoked by `back` (copy it out of the archive, no re-approve).
T="$(mkchain)"; ( cd "$T" && b next >/dev/null && b back -s 3 -r "spec reopened by council" >/dev/null )
cp "$T"/.bones/gates/archive/*/3-spec.ok "$T/.bones/gates/"
V "$T" && no "resurrected archived gate not caught" || ok "attack: gate restored from archive after back caught"; rm -rf "$T"
# Un-killing by flipping the status in state.json instead of `bones back`.
T="$(mkchain)"; ( cd "$T" && b kill -q "stop" -r "not worth building" >/dev/null )
perl -pi -e 's/"status": "killed"/"status": "active"/' "$T/.bones/state.json"
V "$T" && no "status un-kill via state.json not caught" || ok "attack: un-kill by editing state.json caught"; rm -rf "$T"
# Deleting the kill record.
T="$(mkchain)"; ( cd "$T" && b kill -q "stop" -r "not worth building" >/dev/null ); rm "$T/.bones/killed.ok"
V "$T" && no "deleted killed.ok not caught" || ok "attack: deleted kill record caught"; rm -rf "$T"

# ---- 13. build: config reviewer reaches loop.sh, an explicit -R wins ----
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" && BONES_REVIEWER=bogus bash "$BONES" build -c "true" >/dev/null 2>&1 ) && no "config reviewer ignored by build" || ok "build: config reviewer reaches loop.sh"
( cd "$T" && BONES_REVIEWER=bogus bash "$BONES" build -c "true" -R none >/dev/null 2>&1 ) && ok "build: explicit -R overrides config" || no "build: explicit -R did not override config"
rm -rf "$T"

# ---- 14. no-jq fallback parser, with a target path holding a comma ----
P="$(mktemp -d)"; T="$P/my,proj"; mkdir "$T"
( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
BONES_NO_JQ=1 bash "$BONES" init -t "$T" >/dev/null 2>&1
( cd "$T" && BONES_NO_JQ=1 bash "$BONES" approve "brief interrogated, scope pinned" >/dev/null && BONES_NO_JQ=1 bash "$BONES" next >/dev/null )
nojq="$( cd "$T" && BONES_NO_JQ=1 bash "$BONES" status )"
case "$nojq" in *"target=$T"*"stage: 2/10"*) ok "no-jq: state parsed (path with a comma)" ;; *) no "no-jq: state misparsed" ;; esac
( cd "$T" && BONES_NO_JQ=1 bash "$BONES" verify >/dev/null 2>&1 ) && ok "no-jq: chain verifies" || no "no-jq: verify failed"
rm -rf "$P"

# ---- 15. CLI hygiene ----
help_out="$(bash "$BONES" help)"
case "$help_out" in *"Usage: bones"*) ok "help prints usage" ;; *) no "help output broken" ;; esac
T="$(mktemp -d)"
( bash "$BONES" init -t "$T" -n 'bad"name' >/dev/null 2>&1 ) && no "init accepted a quote in the name" || ok "init rejects a name that would break state.json"
rm -rf "$T"

# ---- 16. seal + git anchor: a full rewrite after sealing is caught ----
G() { local d="$1"; shift; git -C "$d" -c user.email=t@t -c user.name=t "$@"; }   # git with an identity
T="$(mkchain)"
# seal commits with the repo's own identity: give the throwaway repo one
G "$T" config user.email t@t; G "$T" config user.name t; G "$T" config commit.gpgsign false
( cd "$T" && bash "$BONES" seal >/dev/null 2>&1 )
G "$T" cat-file -e HEAD:.bones/ledger 2>/dev/null && ok "seal commits .bones/ into git" || no "seal did not commit the ledger"
sv="$( cd "$T" && bash "$BONES" verify 2>&1 )"
case "$sv" in *"anchored: 1 sealed"*) ok "verify reports the sealed anchor" ;; *) no "verify did not report the anchor" "$sv" ;; esac
# more work + a second seal: still a clean prefix chain
( cd "$T" && b next >/dev/null && b approve "council: no blocking objections" >/dev/null && bash "$BONES" seal >/dev/null 2>&1 )
V "$T" && ok "second seal: history stays append-only" || no "second seal broke verify"
# re-init over a sealed pipeline is refused (it would read as a rewrite)
( cd "$T" && bash "$BONES" init -t . -f >/dev/null 2>&1 ) && no "init -f replaced a sealed pipeline" || ok "init -f refuses to replace a sealed pipeline"
# the attack: wipe .bones/ (uncommitted) and forge a fresh, internally valid chain
rm -rf "$T/.bones"
( cd "$T" && b init -t . -n atk >/dev/null 2>&1 && b approve "scope pinned (forged)" >/dev/null && b next >/dev/null \
  && b approve -q "go" "forged commit" >/dev/null )
rw="$( cd "$T" && bash "$BONES" verify 2>&1 )"
case "$rw" in *"CHAIN REWRITTEN"*) ok "attack: full rewrite after seal caught" ;; *) no "full rewrite after seal not caught" "$rw" ;; esac
# the honest path: reset, commit the removal, start over — verify passes and says so
( cd "$T" && bash "$BONES" reset -f >/dev/null 2>&1 )
G "$T" add -A .bones && G "$T" commit -qm "bones: reset" >/dev/null
( cd "$T" && b init -t . -n again >/dev/null 2>&1 && b approve "scope pinned for the new run" >/dev/null )
rs="$( cd "$T" && bash "$BONES" verify 2>&1 )"
case "$rs" in *"CHAIN VERIFIED"*"restarted at git commit"*) ok "explicit reset + commit: new chain verifies, restart reported" ;; *) no "explicit restart not handled" "$rs" ;; esac
rm -rf "$T"

# ---- 17. strict mode: owner decisions need an interactive terminal ----
T="$(mktemp -d)"; ( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
b init -t "$T" -H >/dev/null 2>&1
( cd "$T" && b approve "scope pinned under strict mode" >/dev/null </dev/null ) && ok "strict: agent gates still work non-interactively" || no "strict blocked an agent gate"
( cd "$T" && b next >/dev/null </dev/null )
( cd "$T" && b approve -q "go" "committed" >/dev/null 2>&1 </dev/null ) && no "strict: owner gate passed without a TTY" || ok "strict: owner gate refused without a TTY"
( cd "$T" && b kill -q "stop" -r "not worth it" >/dev/null 2>&1 </dev/null ) && no "strict: kill passed without a TTY" || ok "strict: kill refused without a TTY"
rm -rf "$T"

# ---- 18. config files: ~/.bonesrc, then .bones/config (inline comments ignored) ----
H="$(mktemp -d)"; T="$(mktemp -d)"
( cd "$T" && git init -q && echo x>f && git add -A && git -c user.email=t@t -c user.name=t commit -qm i >/dev/null )
printf 'owner = Alex Doe   # whose call\ntemplate = code\n' > "$H/.bonesrc"
HOME="$H" bash "$BONES" init -t "$T" >/dev/null 2>&1
( cd "$T" && HOME="$H" bash "$BONES" approve "scope pinned real note" >/dev/null && HOME="$H" bash "$BONES" next >/dev/null )
c1="$( cd "$T" && HOME="$H" bash "$BONES" status )"
case "$c1" in *"ALEX DOE'S call"*) ok "config: ~/.bonesrc owner (inline comment stripped)" ;; *) no "config: ~/.bonesrc owner not applied" ;; esac
printf 'owner = Sam\n' > "$T/.bones/config"
c2="$( cd "$T" && HOME="$H" bash "$BONES" status )"
case "$c2" in *"SAM'S call"*) ok "config: .bones/config overrides ~/.bonesrc" ;; *) no "config: .bones/config did not override" ;; esac
rm -rf "$H" "$T"

# ---- 19. log + stats read the trail back ----
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" && b back -s 3 -r "council reopened the spec" >/dev/null )
lg="$( cd "$T" && bash "$BONES" log )"
case "$lg" in *"archived (superseded by back)"*"-- chain (ledger) --"*) ok "log: chain + archive shown" ;; *) no "log output incomplete" ;; esac
st="$( cd "$T" && bash "$BONES" stats )"
case "$st" in *"regressions (back)    : 1"*) ok "stats: regression counted" ;; *) no "stats: regression not counted" "$st" ;; esac
rm -rf "$T"

# ---- 20. evidence pins: a signed -e file that changes or vanishes is reported ----
T="$(mkchain)"     # stage 3 was approved with -e spec.html
ev0="$( cd "$T" && bash "$BONES" verify 2>&1 )"
case "$ev0" in *"1 evidence file(s) still match"*) ok "evidence: intact file reported as matching" ;; *) no "evidence: intact file not reported" "$ev0" ;; esac
echo "spec silently edited after sign-off" > "$T/spec.html"
ev1="$( cd "$T" && bash "$BONES" verify 2>&1 )"; ev1rc=$?
case "$ev1rc:$ev1" in 0:*"EVIDENCE DRIFT"*"spec.html CHANGED"*) ok "evidence: changed file warned (chain still verifies)" ;; *) no "evidence: changed file not warned" "$ev1" ;; esac
( cd "$T" && bash "$BONES" verify --strict >/dev/null 2>&1 ) && no "verify --strict passed with drifted evidence" || ok "evidence: verify --strict fails on a changed file"
rm "$T/spec.html"
ev2="$( cd "$T" && bash "$BONES" verify --strict 2>&1 )"
case "$ev2" in *"spec.html is MISSING"*) ok "evidence: deleted file reported as missing" ;; *) no "evidence: deleted file not reported" "$ev2" ;; esac
rm -rf "$T"
# recorded relative to the target, whatever directory approve ran from
T="$(mktemp -d)"; scaffold "$T"
( cd "$T" && b build -c "true" >/dev/null 2>&1 && b next >/dev/null
  mkdir -p "docs/a b" && echo review > "docs/a b/review.md"
  cd "docs/a b" && b approve -e review.md "review clean; security pass done" >/dev/null 2>&1 )
grep -q '^evidence: docs/a b/review.md (sha256:' "$T/.bones/gates/6-review-security.ok" && ok "evidence: path recorded relative to the target" || no "evidence: path not target-relative"
( cd "$T" && bash "$BONES" verify --strict >/dev/null 2>&1 ) && ok "evidence: found again from the target root" || no "evidence: target-relative path not resolved"
( cd "$T" && mkdir -p d && b approve -e d "a directory is not evidence" >/dev/null 2>&1 ) && no "evidence: a directory was accepted" || ok "evidence: a directory is refused"
rm -rf "$T"

# a moved or cloned project (CI checkout) resolves evidence and target where it IS now
T="$(mkchain)"; T2="$(mktemp -d)/moved"; mv "$T" "$T2"
( cd "$T2" && bash "$BONES" verify --strict >/dev/null 2>&1 ) && ok "moved project: verifies at its new location" || no "moved project: verify failed after a move"
case "$( cd "$T2" && bash "$BONES" status )" in *"target=$T2"*) ok "moved project: status shows the real location" ;; *) no "moved project: status shows the stale path" ;; esac
mkdir -p "$T"; echo spec > "$T/spec.html"   # decoy with the SIGNED content at the old path
echo "edited after the move" > "$T2/spec.html"
( cd "$T2" && bash "$BONES" verify --strict >/dev/null 2>&1 ) && no "moved project: drift checked at the old path" || ok "moved project: drift checked at the new path"
rm -rf "$T" "$(dirname "$T2")"

# ---- 21. status --json: machine-readable state for agents and CI ----
T="$(mkchain)"
js="$( cd "$T" && bash "$BONES" status --json )"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$js" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="active" and d["stage"]==3 and d["current"]["key"]=="spec" and d["current"]["satisfied"] is True' 2>/dev/null \
    && ok "status --json: valid JSON with stage, gate and satisfaction" || no "status --json: wrong or invalid JSON" "$js"
else
  case "$js" in *'"stage": 3,'*'"key": "spec"'*'"satisfied": true'*) ok "status --json: stage, gate and satisfaction" ;; *) no "status --json: wrong output" "$js" ;; esac
fi
( cd "$T" && b kill -q "stop" -r "not worth it" >/dev/null )
case "$( cd "$T" && bash "$BONES" status --json )" in *'"status": "killed"'*) ok "status --json: reports killed" ;; *) no "status --json: killed not reported" ;; esac
rm -rf "$T"

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
