#!/usr/bin/env bash
#
# bones — the gated, tamper-evident ship pipeline.
#
# A checklist you could skip, turned into a state machine that refuses to advance:
# bones tracks the current stage in .bones/state.json and REFUSES to move past a
# gate until that gate is satisfied, recording every gate into an append-only,
# hash-chained ledger that `bones verify` can later prove was not faked.
#
# Gate types:
#   owner  — the owner's call. Needs their VERBATIM words via `approve -q "<quote>"`.
#            Strict mode (init -H) also requires an interactive terminal on stdin,
#            so a non-interactive agent shell cannot satisfy it.
#   agent  — a judgment call. Needs a substantive note (evidence via -e strongly
#            encouraged; warned when missing on evidence-heavy stages).
#   auto   — machine-verified. Only `bones build` + loop.sh exit 0 opens it.
#   step   — no approval; `next` advances and records the step.
#
# The default "code" template (templates/code.tsv):
#   1  brainstorm        [agent]  brief interrogated, scope + non-goals pinned
#   2  kill-or-commit    [owner]  the owner committed (or killed it: `bones kill`)
#   3  spec              [owner]  the owner signed off the spec
#   4  council           [agent]  second-pass critique recorded
#   5  build-loop        [auto]   acceptance check exited 0 (`bones build`)
#   6  review-security   [agent]  adversarial review + security pass done
#   7  staging           [agent]  staging validation green BEFORE promote
#   8  promote           [owner]  the owner's explicit go for production
#   9  present           [step]   presented
#   10 operate           [owner]  operate/learn decision (double-down/park/kill)
#
# Tamper-evidence: every satisfied gate appends a link to .bones/ledger embedding
# the sha256 of the previous link, of the gate record and the target's git commit.
# `bones verify` recomputes the chain and fails on any edit, insertion, deletion,
# truncation, forged or resurrected gate file, or a stage skipped by editing state.
# `bones seal` commits .bones/; from then on verify requires every sealed version
# of the ledger to be a prefix of the live one, so even a consistent rewrite shows.
#
# Run `bones help` for usage.
#
set -uo pipefail

BONES_VERSION="1.2.0"

# Resolve this script's real directory (following symlinks, e.g. ~/.local/bin/bones),
# so we can find the shipped loop.sh and templates/ regardless of how bones was invoked.
_selfdir() {
  local s="$0" d
  while [ -h "$s" ]; do
    d="$(cd "$(dirname "$s")" && pwd)"; s="$(readlink "$s")"
    case "$s" in /*) ;; *) s="$d/$s" ;; esac
  done
  cd "$(dirname "$s")" && pwd
}
SCRIPT_DIR="$(_selfdir)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="${BONES_TEMPLATES_DIR:-$SKILL_DIR/templates}"

# loop.sh (the acceptance build loop) lives beside this script in the repo; fall
# back to a Claude Code skill install if someone runs the two from there.
if [ -n "${BONES_LOOP_SH:-}" ]; then
  LOOP_SH="$BONES_LOOP_SH"
else
  LOOP_SH="$SCRIPT_DIR/loop.sh"
  [ -f "$LOOP_SH" ] || LOOP_SH="$SKILL_DIR/../ship-pipeline/scripts/loop.sh"
  [ -f "$LOOP_SH" ] || LOOP_SH="$HOME/.claude/skills/ship-pipeline/scripts/loop.sh"
fi

STAGE_KEYS=(brainstorm kill-or-commit spec council build-loop review-security staging promote present operate)
STAGE_TITLES=(
  "Brainstorm + prompt interrogation"
  "Kill-or-commit"
  "Spec sign-off"
  "Council / second-pass critique"
  "Build loop (acceptance gate)"
  "Adversarial review + security"
  "Staging validation"
  "Promote + production smoke test"
  "Present"
  "Operate + learn"
)
# gate type per stage: owner | agent | auto | step (see header)
STAGE_GATE=(agent owner owner agent auto agent agent owner step owner)
# stages where approving without -e evidence draws a loud warning
EVIDENCE_STAGES=" 3 6 7 "
NSTAGES=${#STAGE_KEYS[@]}

die() { printf 'bones: %s\n' "$1" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- configuration ---------------------------------------------------------
# Resolution order (last wins): built-in default → ~/.bonesrc → .bones/config
# → environment (BONES_OWNER, BONES_TEMPLATE, …). Keeps "the owner" as the default
# owner while making the tool shareable: anyone drops their own ~/.bonesrc.
OWNER="the owner"; TEMPLATE="code"; REVIEWER="auto"; SIGN="0"
read_config_file() { # read_config_file <path>
  [ -f "$1" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$key" in ''|\#*) continue ;; esac
    val="${val%%#*}"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
    case "$key" in
      owner)    OWNER="$val" ;;
      template) TEMPLATE="$val" ;;
      reviewer) REVIEWER="$val" ;;
      sign)     SIGN="$val" ;;
    esac
  done < "$1"
}
load_config() {
  read_config_file "$HOME/.bonesrc"
  [ -n "${BONES_DIR:-}" ] && read_config_file "$BONES_DIR/config"
  OWNER="${BONES_OWNER:-$OWNER}"
  TEMPLATE="${BONES_TEMPLATE:-$TEMPLATE}"
  REVIEWER="${BONES_REVIEWER:-$REVIEWER}"
  SIGN="${BONES_SIGN:-$SIGN}"
}
OWNER_UP() { printf '%s' "$OWNER" | tr '[:lower:]' '[:upper:]'; }

# --- pipeline stages: built-in "code" arrays are the default & fallback -----
# A pipeline records its own stage list in .bones/pipeline.tsv (key<TAB>title<TAB>
# gate<TAB>evidence), so it stays self-describing even if templates change.
load_stages() {
  local f="${BONES_DIR:-/nonexistent}/pipeline.tsv"
  [ -f "$f" ] || return 0                       # old pipeline → keep built-in arrays
  STAGE_KEYS=(); STAGE_TITLES=(); STAGE_GATE=(); EVIDENCE_STAGES=" "
  local i=0 key title gate ev
  while IFS="$(printf '\t')" read -r key title gate ev; do
    case "$key" in ''|\#*) continue ;; esac
    i=$((i+1))
    STAGE_KEYS+=("$key"); STAGE_TITLES+=("$title"); STAGE_GATE+=("$gate")
    [ "${ev:-0}" = "1" ] && EVIDENCE_STAGES="${EVIDENCE_STAGES}$i "
  done < "$f"
  NSTAGES=${#STAGE_KEYS[@]}
}
# Write the chosen template's stage list into a pipeline's pipeline.tsv.
write_pipeline_tsv() { # write_pipeline_tsv <dest>
  local dest="$1" tf="$TEMPLATES_DIR/$TEMPLATE.tsv"
  if [ -f "$tf" ]; then
    cp "$tf" "$dest"
  elif [ "$TEMPLATE" = "code" ]; then
    local i=0 ev
    : > "$dest"
    while [ "$i" -lt "${#STAGE_KEYS[@]}" ]; do
      ev=0; printf '%s' "$EVIDENCE_STAGES" | grep -q " $((i+1)) " && ev=1
      printf '%s\t%s\t%s\t%s\n' "${STAGE_KEYS[$i]}" "${STAGE_TITLES[$i]}" "${STAGE_GATE[$i]}" "$ev" >> "$dest"
      i=$((i+1))
    done
  else
    die "unknown template '$TEMPLATE' — looked in $TEMPLATES_DIR. Available: $(ls "$TEMPLATES_DIR" 2>/dev/null | sed 's/\.tsv$//' | tr '\n' ' ')"
  fi
}
# Every command loads config + the pipeline's own stage list before doing work.
bootstrap() { load_config; load_stages; }

# --- timing helpers (portable across macOS/BSD date and GNU date) -----------
epoch_of() { # ISO8601 "…Z" -> epoch seconds on stdout; nothing (rc 1) if unparseable
  local ts="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null && return 0   # macOS/BSD
  date -u -d "$ts" +%s 2>/dev/null                                       # GNU
}
elapsed_since() { # ISO ts -> whole seconds from then to now (never negative)
  local a b d; a="$(epoch_of "$1")" || return 1; b="$(date -u +%s)"
  d=$((b - a)); [ "$d" -lt 0 ] && d=0; printf '%s' "$d"
}
human_dur() { # seconds -> "1h2m" / "3m4s" / "12s"
  local s="${1:-}"; case "$s" in ''|*[!0-9]*) printf '?'; return ;; esac
  local h=$((s/3600)) m=$(((s%3600)/60)) sec=$((s%60))
  if   [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm%ds' "$m" "$sec"
  else printf '%ds' "$sec"; fi
}

# Locate .bones by walking up from CWD (so subcommands work anywhere in the target).
find_bones() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -d "$d/.bones" ] && { printf '%s\n' "$d/.bones"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

json_get() { # json_get <file> <key>
  if [ -z "${BONES_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then   # BONES_NO_JQ=1 forces the fallback (tests)
    jq -r --arg k "$2" '.[$k] | if . == null then empty else . end' "$1" 2>/dev/null
  else
    # quoted values may hold commas/colons (paths); bones never writes '"' inside one
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}[:space:]]*)" "$1" 2>/dev/null \
      | head -1 | sed -E "s/^\"[^\"]*\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
  fi
}

write_state() { # write_state <dir> <name> <target> <stage> <created> <strict>
  # Preserve the chain head + lifecycle status across stage transitions.
  local head status
  head="$(json_get "$1/state.json" head 2>/dev/null)"; [ -n "$head" ] || head="$GENESIS"
  status="$(json_get "$1/state.json" status 2>/dev/null)"; [ -n "$status" ] || status="active"
  printf '{\n  "name": "%s",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": %s,\n  "status": "%s",\n  "head": "%s"\n}\n' \
    "$2" "$3" "$4" "$5" "$(now)" "${6:-false}" "$status" "$head" | atomic_write "$1/state.json"
}

state_get() { json_get "$BONES_DIR/state.json" "$1"; }

journal() { printf '%s | %s | %s\n' "$(now)" "$1" "$2" >> "$BONES_DIR/journal.log"; }

gate_file() { printf '%s/gates/%s-%s.ok\n' "$BONES_DIR" "$1" "${STAGE_KEYS[$(( $1 - 1 ))]}"; }
gate_satisfied() { [ -f "$(gate_file "$1")" ]; }

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo "sha-unavailable"; fi
}

# --- tamper-evident audit chain (Tier 1) -----------------------------------
# Every satisfied gate appends a link to .bones/ledger. Each link embeds the
# hash of the previous link (git-style), so editing, inserting, deleting or
# reordering any record breaks the chain — `bones verify` recomputes and detects
# it. The chain head is mirrored in state.json ("head") to catch truncation.
GENESIS="0000000000000000000000000000000000000000000000000000000000000000"

sha_stdin() { # sha256 of stdin
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else echo "sha-unavailable"; fi
}

atomic_write() { # atomic_write <dest>  (content on stdin) — never leaves a half-written file
  local dest="$1" dir tmp
  dir="${dest%/*}"; [ "$dir" = "$dest" ] && dir="."
  tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || { cat > "$dest"; return; }
  if cat > "$tmp"; then mv -f "$tmp" "$dest"; else rm -f "$tmp"; return 1; fi
}

git_ref() { # short commit + clean/dirty for the target repo, or "no-git"
  local t; t="$(state_get target 2>/dev/null)"; [ -n "$t" ] || t="$PWD"
  if command -v git >/dev/null 2>&1 && git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    local sha dirty
    sha="$(git -C "$t" rev-parse --short HEAD 2>/dev/null || echo nocommit)"
    [ -n "$(git -C "$t" status --porcelain 2>/dev/null)" ] && dirty=dirty || dirty=clean
    printf '%s-%s' "$sha" "$dirty"
  else
    printf 'no-git'
  fi
}

# True (rc 0) when <bones_dir>/ledger is part of the target repo's HEAD commit,
# i.e. the chain has been sealed and not explicitly removed since.
ledger_sealed_in_head() { # ledger_sealed_in_head <bones_dir>
  command -v git >/dev/null 2>&1 || return 1
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$1" cat-file -e "HEAD:./ledger" 2>/dev/null
}

chain_head() { local h; h="$(state_get head 2>/dev/null)"; [ -n "$h" ] && printf '%s' "$h" || printf '%s' "$GENESIS"; }

# True (rc 0) when NO ledger link is bound to a real git commit — the chain is
# tamper-evident but NOT externally anchored (git's own history can't catch a full
# rewrite). Used to warn in `status`/`verify` so the audit's strength isn't oversold.
chain_unanchored() {
  local f="$BONES_DIR/ledger" g s1
  [ -f "$f" ] || return 0
  while IFS="|" read -r s1 _ _ _ _ g _; do
    [ -z "${s1:-}" ] && continue
    case "$g" in no-git|"") ;; *) return 1 ;; esac
  done < "$f"
  return 0
}

set_head() { # rewrite state.json's head atomically, preserving all other fields
  local newhead="$1" f="$BONES_DIR/state.json" name target stage created updated strict status
  name="$(json_get "$f" name)"; target="$(json_get "$f" target)"; stage="$(json_get "$f" stage)"
  created="$(json_get "$f" created)"; updated="$(json_get "$f" updated)"; strict="$(json_get "$f" strict)"
  status="$(json_get "$f" status)"; [ -n "$status" ] || status="active"
  printf '{\n  "name": "%s",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": %s,\n  "status": "%s",\n  "head": "%s"\n}\n' \
    "$name" "$target" "$stage" "$created" "$updated" "${strict:-false}" "$status" "$newhead" | atomic_write "$f"
}

set_status() { # set_status <newstatus> — rewrite state.json's lifecycle status, preserving all else
  local ns="$1" f="$BONES_DIR/state.json" name target stage created updated strict head
  name="$(json_get "$f" name)"; target="$(json_get "$f" target)"; stage="$(json_get "$f" stage)"
  created="$(json_get "$f" created)"; updated="$(json_get "$f" updated)"; strict="$(json_get "$f" strict)"
  head="$(json_get "$f" head)"; [ -n "$head" ] || head="$GENESIS"
  printf '{\n  "name": "%s",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": %s,\n  "status": "%s",\n  "head": "%s"\n}\n' \
    "$name" "$target" "$stage" "$created" "$updated" "${strict:-false}" "$ns" "$head" | atomic_write "$f"
}

# True when the pipeline has been terminally killed (owner decision to stop).
is_killed() { [ "$(state_get status 2>/dev/null)" = "killed" ]; }

# ledger_append <event> <stage> <gatetype> <content_sha> [<rel_path>]
# Line format (10 fields): seq|ts|event|stage|gate|git|prev|rel|content_sha|hash
# where hash = sha256(the first 9 fields joined by '|').
ledger_append() {
  local ev="$1" st="$2" gt="$3" csha="$4" rel="${5:--}" seq ts git prev canon hash
  ts="$(now)"; git="$(git_ref)"; prev="$(chain_head)"
  seq=1; [ -f "$BONES_DIR/ledger" ] && seq=$(( $(wc -l < "$BONES_DIR/ledger") + 1 ))
  canon="$seq|$ts|$ev|$st|$gt|$git|$prev|$rel|$csha"
  hash="$(printf '%s' "$canon" | sha_stdin)"
  printf '%s|%s\n' "$canon" "$hash" >> "$BONES_DIR/ledger"
  set_head "$hash"
}

gate_rel() { printf 'gates/%s-%s.ok' "$1" "${STAGE_KEYS[$(( $1 - 1 ))]}"; }

# Optional GPG signing of the chain head at owner gates (non-repudiation).
# Enabled with config `sign=1`. Best-effort: a signing failure warns but never
# blocks the gate — the owner quote is still on record; the signature is a bonus.
sign_head() {
  [ "$SIGN" = "1" ] || return 0
  if ! command -v gpg >/dev/null 2>&1; then
    printf 'bones: WARNING — sign=1 but gpg not found; owner gate recorded UNSIGNED.\n' >&2; return 0
  fi
  local head tmp; head="$(chain_head)"
  mkdir -p "$BONES_DIR/sigs"
  tmp="$(mktemp)"; printf '%s' "$head" > "$tmp"
  if gpg --batch --yes --detach-sign --armor -o "$BONES_DIR/sigs/$head.asc" "$tmp" 2>/dev/null; then
    printf '       owner consent GPG-signed (head %s…)\n' "$(printf '%s' "$head" | cut -c1-12)"
  else
    printf 'bones: WARNING — gpg signing failed; owner gate recorded UNSIGNED.\n' >&2
  fi
  rm -f "$tmp"
}

# --- concurrency lock (portable: mkdir is atomic; no flock on macOS) --------
# Serializes state-mutating commands so two `bones` runs can't interleave a
# ledger append or a state write. A lock whose holder PID is dead is stolen.
BONES_LOCK=""
LOCK_WAIT="${BONES_LOCK_WAIT:-10}"   # seconds to wait before giving up
release_lock() { [ -n "$BONES_LOCK" ] && rm -rf "$BONES_LOCK" 2>/dev/null; BONES_LOCK=""; }
acquire_lock() {
  local lock="$BONES_DIR/.lock" tries=0 max=$((LOCK_WAIT*10)) lpid
  while ! mkdir "$lock" 2>/dev/null; do
    lpid="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
      rm -rf "$lock" 2>/dev/null; continue          # holder is dead → steal
    fi
    tries=$((tries+1))
    [ "$tries" -gt "$max" ] && die "could not acquire lock (held by PID ${lpid:-?} at $lock). If it is stale, remove that dir."
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid"
  BONES_LOCK="$lock"
  trap 'release_lock' EXIT INT TERM
}

stage_line() { # stage_line <n> <current>
  local n="$1" cur="$2" mark key title extra=""
  key="${STAGE_KEYS[$((n-1))]}"; title="${STAGE_TITLES[$((n-1))]}"
  if [ "$n" -lt "$cur" ] || gate_satisfied "$n"; then
    mark="✓"
    if [ -f "$(gate_file "$n")" ]; then
      extra="$(head -1 "$(gate_file "$n")" | cut -d'|' -f4- | sed -E 's/^ +//' | cut -c1-56)"
      [ -n "$extra" ] && extra="  — ${extra}"
    fi
  elif [ "$n" -eq "$cur" ]; then mark="▶"
  else mark="·"; fi
  printf '  %s  %s. %-32s [%s]%s\n' "$mark" "$n" "$title" "${STAGE_GATE[$((n-1))]}" "$extra"
}

# --- subcommands -----------------------------------------------------------

cmd_init() {
  local target="" name="" force=0 strict=false tmpl=""
  while getopts ":t:n:T:fH" o; do case "$o" in
    t) target="$OPTARG" ;; n) name="$OPTARG" ;; T) tmpl="$OPTARG" ;; f) force=1 ;; H) strict=true ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  load_config                       # for default TEMPLATE (config/env)
  [ -n "$tmpl" ] && TEMPLATE="$tmpl"   # -T flag wins
  [ -n "$target" ] || die "init needs -t <target_dir>"
  [ -d "$target" ] || die "target dir not found: $target"
  target="$(cd "$target" && pwd)"
  [ -z "$name" ] && name="$(basename "$target")"
  # state.json is written without a JSON library: keep its strings unambiguous.
  case "$name$target" in
    *'"'*|*'\'*|*$'\n'*) die "pipeline name and target path may not contain '\"', '\\' or newlines" ;;
  esac
  local dir="$target/.bones"
  if [ -d "$dir" ] && [ "$force" -ne 1 ]; then
    die "already initialized at $dir (use 'init -f' to reset, or 'status')"
  fi
  if [ -d "$dir" ] && ledger_sealed_in_head "$dir"; then
    die "this pipeline is sealed in git — replacing it would read as a rewrite. Run 'bones reset -f', commit the removal of .bones/, then 'bones init'."
  fi
  rm -rf "$dir"; mkdir -p "$dir/gates"
  printf '.lock/\n.tmp.*\n' > "$dir/.gitignore"   # runtime scratch never gets committed/anchored
  local created; created="$(now)"
  write_state "$dir" "$name" "$target" 1 "$created" "$strict"
  BONES_DIR="$dir"
  acquire_lock
  write_pipeline_tsv "$dir/pipeline.tsv"   # freeze the chosen template into this pipeline
  load_stages                              # use it from here on
  : > "$dir/ledger"
  # Genesis link: anchors the chain to this pipeline's identity + stage list.
  ledger_append init 0 genesis "$(printf '%s|%s|%s|%s' "$name" "$target" "$created" "$TEMPLATE" | sha_stdin)"
  journal init "pipeline \"$name\" initialized (template=$TEMPLATE, strict=$strict, $NSTAGES stages)"
  printf 'bones: initialized pipeline "%s" at %s\n' "$name" "$dir"
  printf '       template=%s · %s stages · strict=%s\n' "$TEMPLATE" "$NSTAGES" "$strict"
  printf '       audit chain started — every gate is cryptographically linked; `bones verify` checks it.\n'
  if command -v git >/dev/null 2>&1 && git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
    :
  else
    printf '\nbones: ⚠ target is NOT a git repository.\n'
    printf '       The chain is still tamper-evident, but its git-commit binding is empty\n'
    printf '       (links record "no-git") and `bones seal` (the external anchor) is unavailable.\n'
    printf '       For a fully anchored audit trail: `git init` in %s, then commit as you go.\n' "$target"
  fi
  printf '\n'
  cmd_status
}

cmd_status() {
  BONES_DIR="${BONES_DIR:-$(find_bones)}" || die "no .bones here — run 'bones init -t <dir>' first"
  bootstrap
  local cur name target strict created updated
  cur="$(state_get stage)"; name="$(state_get name)"; target="$(state_get target)"; strict="$(state_get strict)"
  created="$(state_get created)"; updated="$(state_get updated)"
  printf '== bones pipeline: %s ==\n target=%s\n owner=%s  strict=%s\n' "$name" "$target" "$OWNER" "${strict:-false}"
  chain_unanchored && printf ' audit: ⚠ UNANCHORED (no-git) — tamper-evident but not committed; `git init` + `bones seal` to anchor.\n'
  # Terminal state: the owner killed this build. Distinct from a merely-open gate.
  if is_killed; then
    local kf="$BONES_DIR/killed.ok" kq=""
    [ -f "$kf" ] && kq="$(sed -n 's/^owner-quote: //p' "$kf" | head -1)"
    printf ' status: ☠ KILLED at stage %s/%s — %s\n' "$cur" "$NSTAGES" "${STAGE_TITLES[$((cur-1))]}"
    [ -n "$kq" ] && printf ' owner said: %s\n' "$kq"
    printf '\n'
    local n=1; while [ "$n" -le "$NSTAGES" ]; do stage_line "$n" "$cur"; n=$((n+1)); done
    printf '\nThis build was stopped by %s'\''s decision. It holds no open gate.\n' "$(OWNER_UP)"
    printf 'To revive it (only if %s reverses): `bones back -s <stage> -r "<reason>"`.\n' "$OWNER"
    return 0
  fi
  if [ "$cur" -gt "$NSTAGES" ] 2>/dev/null; then
    local total; total="$(elapsed_since "$created" 2>/dev/null)"
    printf ' status: ALL STAGES COMPLETE ✓%s\n\n' "${total:+  (total: $(human_dur "$total"))}"
    local n=1; while [ "$n" -le "$NSTAGES" ]; do stage_line "$n" "$((NSTAGES+1))"; n=$((n+1)); done
    return 0
  fi
  local instage; instage="$(elapsed_since "$updated" 2>/dev/null)"
  printf ' stage: %s/%s — %s%s\n\n' "$cur" "$NSTAGES" "${STAGE_TITLES[$((cur-1))]}" "${instage:+  (in stage: $(human_dur "$instage"))}"
  local n=1; while [ "$n" -le "$NSTAGES" ]; do stage_line "$n" "$cur"; n=$((n+1)); done
  printf '\n'
  local gt="${STAGE_GATE[$((cur-1))]}"
  if gate_satisfied "$cur"; then
    printf 'current gate satisfied ✓ — run `bones next` to advance.\n'
  else
    case "$gt" in
      owner) printf 'GATE OPEN [owner] — this is %s'\''S call. Do stage %s, ask them, then record their\n  verbatim words: `bones approve -q "<their exact words>" "<note>"`.\n  No quote = no approval. If they are unreachable, the gate stays open.\n' "$(OWNER_UP)" "$cur" ;;
      agent) printf 'GATE OPEN [agent] — do stage %s, then record a substantive note (+ evidence):\n  `bones approve [-e <file>]... "<what was done and verified>"`.\n' "$cur" ;;
      auto)  printf 'GATE OPEN [auto] — machine-verified. Run `bones build -c "<acceptance_cmd>" -s <spec> [...]`;\n  it passes only on loop.sh exit 0.\n  No test harness yet (e.g. a static site)? Copy %s/scripts/acceptance-example.sh\n  into the target as check.sh, add real assertions, then: bones build -c "./check.sh".\n' "$SKILL_DIR" ;;
      step)  printf 'STEP — do stage %s, then `bones next` (no approval needed).\n' "$cur" ;;
    esac
  fi
}

cmd_approve() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  bootstrap
  local cur quote="" evidence=() strict
  cur="$(state_get stage)"; strict="$(state_get strict)"
  is_killed && die "pipeline was KILLED — it holds no open gate. Revive with 'bones back -s <n> -r \"<reason>\"' if $OWNER reverses."
  [ "$cur" -le "$NSTAGES" ] 2>/dev/null || die "pipeline already complete"
  local gt="${STAGE_GATE[$((cur-1))]}"
  case "$gt" in
    auto) die "stage $cur is machine-verified — run 'bones build', you cannot approve past the build gate" ;;
    step) die "stage $cur is a step, not a gate — just run 'bones next'" ;;
  esac

  while getopts ":q:e:" o; do case "$o" in
    q) quote="$OPTARG" ;;
    e) evidence+=("$OPTARG") ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  shift $((OPTIND-1))
  local note="${*:-}"

  # A gate record must say something. "approved" says nothing.
  case "$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')" in
    ""|approved|approve|ok|done|lgtm|yes)
      die "note too thin — record WHAT was decided/verified, not just that it was" ;;
  esac

  if [ "$gt" = "owner" ]; then
    if [ "$strict" = "true" ] && [ ! -t 0 ]; then
      die "STRICT MODE: stage $cur is an owner gate — $OWNER must run this approve themselves from an interactive terminal. A non-interactive agent shell cannot satisfy it."
    fi
    [ -n "$quote" ] || die "stage $cur is an OWNER gate — it needs $OWNER's verbatim words: approve -q \"<their exact words>\" \"<note>\". Ask them; do not paraphrase or infer."
  fi

  # Evidence: every -e must exist; record path + sha256.
  local ev_lines=""
  if [ ${#evidence[@]} -gt 0 ]; then
    local f
    for f in "${evidence[@]}"; do
      [ -e "$f" ] || die "evidence file not found: $f"
      ev_lines="${ev_lines}evidence: $f (sha256:$(sha_of "$f"))
"
    done
  elif printf '%s' "$EVIDENCE_STAGES" | grep -q " $cur "; then
    printf 'bones: WARNING — stage %s usually has artifacts (spec/review/staging logs). Approving with no -e evidence weakens the audit trail.\n' "$cur" >&2
  fi

  local gf; gf="$(gate_file "$cur")"
  {
    printf '%s | %s | %s | %s\n' "$(now)" "${STAGE_KEYS[$((cur-1))]}" "$gt" "$note"
    [ -n "$quote" ] && printf 'owner-quote: "%s"\n' "$quote"
    [ -n "$ev_lines" ] && printf '%s' "$ev_lines"
    printf 'git: %s\n' "$(git_ref)"
  } > "$gf"
  # Sign this gate into the tamper-evident chain (binds note+quote+evidence+commit).
  ledger_append approve "$cur" "$gt" "$(sha_of "$gf")" "$(gate_rel "$cur")"
  [ "$gt" = "owner" ] && sign_head    # optional GPG non-repudiation on owner consent
  journal approve "stage $cur (${STAGE_KEYS[$((cur-1))]}) — $note"
  printf 'bones: gate %s. %s approved — "%s"\n' "$cur" "${STAGE_TITLES[$((cur-1))]}" "$note"
  [ -n "$quote" ] && printf '       owner quote on record: "%s"\n' "$quote"
  printf '       signed into audit chain @ %s (head %s…)\n' "$(git_ref)" "$(chain_head | cut -c1-12)"
  printf 'run `bones next` to advance.\n'
}

cmd_build() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  bootstrap
  local cur target
  cur="$(state_get stage)"; target="$(state_get target)"
  is_killed && die "pipeline was KILLED — no build to run. Revive with 'bones back -s <n> -r \"<reason>\"' if $OWNER reverses."
  [ "$cur" -le "$NSTAGES" ] 2>/dev/null || die "pipeline already complete"
  [ "${STAGE_GATE[$((cur-1))]}" = "auto" ] || die "build is only valid on an AUTO (machine-verified) gate — stage $cur is a ${STAGE_GATE[$((cur-1))]} gate. Advance to the build stage first."
  local build_idx="$cur"
  [ -x "$LOOP_SH" ] || [ -f "$LOOP_SH" ] || die "loop.sh not found at $LOOP_SH (set BONES_LOOP_SH to override)"
  printf 'bones: running build loop (loop.sh) — gate passes only on exit 0...\n\n'
  # Config/env `reviewer` is the default -R; an explicit -R in the args wins
  # (loop.sh's getopts keeps the last value).
  if bash "$LOOP_SH" -t "$target" -R "$REVIEWER" "$@"; then
    {
      printf '%s | %s | auto | loop.sh exit 0 (machine-verified; args: %s)\n' "$(now)" "${STAGE_KEYS[$((build_idx-1))]}" "$*"
      printf 'git: %s\n' "$(git_ref)"
    } > "$(gate_file "$build_idx")"
    ledger_append build "$build_idx" auto "$(sha_of "$(gate_file "$build_idx")")" "$(gate_rel "$build_idx")"
    journal build "loop.sh exit 0 (args: $*)"
    printf '\nbones: build gate PASSED (verified by loop.sh exit 0; signed into chain). Run `bones next`.\n'
  else
    local rc=$?
    journal build "loop.sh exit $rc — gate stays closed"
    printf '\nbones: build gate NOT passed (loop.sh exit %s). Gate stays closed; fix and re-run `bones build`.\n' "$rc"
    return "$rc"
  fi
}

cmd_next() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  bootstrap
  local cur name target created strict updated
  cur="$(state_get stage)"; name="$(state_get name)"
  target="$(state_get target)"; created="$(state_get created)"; strict="$(state_get strict)"
  updated="$(state_get updated)"
  is_killed && die "pipeline was KILLED — it does not advance. Revive with 'bones back -s <n> -r \"<reason>\"' if $OWNER reverses."
  [ "$cur" -le "$NSTAGES" ] 2>/dev/null || die "pipeline already complete"
  local gt="${STAGE_GATE[$((cur-1))]}"
  if [ "$gt" = "step" ]; then
    # steps advance freely, but still leave an audit record — signed into the chain
    printf '%s | %s | step | step completed\n' "$(now)" "${STAGE_KEYS[$((cur-1))]}" > "$(gate_file "$cur")"
    ledger_append step "$cur" step "$(sha_of "$(gate_file "$cur")")" "$(gate_rel "$cur")"
    journal step "stage $cur (${STAGE_KEYS[$((cur-1))]}) completed"
  elif ! gate_satisfied "$cur"; then
    case "$gt" in
      auto)  die "GATE CLOSED: stage $cur (${STAGE_KEYS[$((cur-1))]}) not machine-verified. Run 'bones build ...' until loop.sh exits 0." ;;
      owner) die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) is $(OWNER_UP)'S call. Ask them, then: bones approve -q \"<their exact words>\" \"<note>\"" ;;
      *)     die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) needs sign-off. Run: bones approve \"<note>\"" ;;
    esac
  fi
  # How long this stage took (entry time = state.updated, set when we landed on it).
  local secs dur=""
  secs="$(elapsed_since "$updated" 2>/dev/null)" && dur="$(human_dur "$secs")"
  [ -n "$dur" ] && journal timing "stage $cur (${STAGE_KEYS[$((cur-1))]}) took $dur (${secs}s)"
  local nxt=$((cur+1))
  write_state "$BONES_DIR" "$name" "$target" "$nxt" "$created" "$strict"
  if [ "$nxt" -gt "$NSTAGES" ]; then
    local total=""; secs="$(elapsed_since "$created" 2>/dev/null)" && total="$(human_dur "$secs")"
    journal "done" "all $NSTAGES stages complete${total:+ (total: $total)}"
    printf 'bones: stage %s complete%s. 🎉 ALL STAGES DONE — pipeline shipped & gated end to end.%s\n' \
      "$cur" "${dur:+ ($dur)}" "${total:+  total: $total}"
  else
    printf 'bones: advanced to stage %s/%s — %s%s\n\n' \
      "$nxt" "$NSTAGES" "${STAGE_TITLES[$((nxt-1))]}" "${dur:+  (stage $cur took $dur)}"
    cmd_status
  fi
}

cmd_back() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  bootstrap
  local to="" reason=""
  while getopts ":s:r:" o; do case "$o" in
    s) to="$OPTARG" ;; r) reason="$OPTARG" ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  case "$to" in (''|*[!0-9]*) die "back needs -s <stage_number> to return to" ;; esac
  [ -n "$reason" ] || die "back needs -r \"<reason>\" — regressions are part of the audit trail"
  local cur name target created strict
  cur="$(state_get stage)"; name="$(state_get name)"
  target="$(state_get target)"; created="$(state_get created)"; strict="$(state_get strict)"
  [ "$to" -ge 1 ] && [ "$to" -le "$NSTAGES" ] || die "stage must be 1..$NSTAGES"
  [ "$to" -le "$cur" ] || die "back only goes backward (you are at stage $cur); use gates + next to go forward"
  # Archive (don't delete) every gate record from the target stage on — audit trail survives.
  local arch; arch="$BONES_DIR/gates/archive/$(now | tr ":" "-")-back-to-$to"
  local n="$to" moved=0
  while [ "$n" -le "$NSTAGES" ]; do
    if [ -f "$(gate_file "$n")" ]; then
      mkdir -p "$arch"; mv "$(gate_file "$n")" "$arch/"; moved=$((moved+1))
    fi
    n=$((n+1))
  done
  # Reviving a killed pipeline is a legitimate reversal: archive the kill record and reopen.
  local revived=0
  if is_killed; then
    mkdir -p "$arch"; [ -f "$BONES_DIR/killed.ok" ] && mv "$BONES_DIR/killed.ok" "$arch/"
    revived=1
  fi
  write_state "$BONES_DIR" "$name" "$target" "$to" "$created" "$strict"
  [ "$revived" -eq 1 ] && set_status active
  # Record the regression as its own chain link — going backward is part of the story.
  ledger_append back "$to" regress "$(printf 'back:%s->%s:%s' "$cur" "$to" "$reason" | sha_stdin)"
  local rev_txt=""; [ "$revived" -eq 1 ] && rev_txt=", revived from killed"
  journal back "regressed stage $cur -> $to ($moved gate record(s) archived$rev_txt): $reason"
  printf 'bones: went back to stage %s — %s (archived %s gate record(s)%s; reason on the journal, regression signed into chain)\n\n' "$to" "${STAGE_TITLES[$((to-1))]}" "$moved" "$([ "$revived" -eq 1 ] && printf ', revived from KILLED')"
  cmd_status
}

cmd_kill() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  bootstrap
  local quote="" reason="" cur strict
  while getopts ":q:r:" o; do case "$o" in
    q) quote="$OPTARG" ;; r) reason="$OPTARG" ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  shift $((OPTIND-1))
  local note="${*:-}"
  cur="$(state_get stage)"; strict="$(state_get strict)"
  is_killed && die "pipeline is already killed — nothing to do (see 'bones status')"
  # Kill is the OWNER's decision to STOP. It needs their verbatim words, like any owner gate.
  if [ "$strict" = "true" ] && [ ! -t 0 ]; then
    die "STRICT MODE: kill is $(OWNER_UP)'S decision — they must run this from an interactive terminal. A non-interactive agent shell cannot satisfy it."
  fi
  [ -n "$quote" ] || die "kill is an OWNER decision — it needs $OWNER's verbatim words: kill -q \"<their exact words>\" -r \"<reason>\". Ask them; do not paraphrase or infer."
  [ -n "$reason" ] || die "kill needs -r \"<reason>\" — why the build is being stopped (goes on the permanent record)"
  local kf="$BONES_DIR/killed.ok"
  {
    printf '%s | KILLED at stage %s (%s) | %s\n' "$(now)" "$cur" "${STAGE_KEYS[$((cur-1))]}" "${note:-$reason}"
    printf 'owner-quote: "%s"\n' "$quote"
    printf 'reason: %s\n' "$reason"
    printf 'git: %s\n' "$(git_ref)"
  } > "$kf"
  # Terminal link in the tamper-evident chain — distinct from any stage gate.
  ledger_append kill "$cur" owner "$(sha_of "$kf")" "killed.ok"
  sign_head                         # optional GPG non-repudiation on the owner's stop decision
  set_status killed
  journal kill "KILLED at stage $cur (${STAGE_KEYS[$((cur-1))]}) — $reason${note:+ · $note}"
  printf 'bones: ☠ pipeline KILLED at stage %s/%s (%s).\n' "$cur" "$NSTAGES" "${STAGE_TITLES[$((cur-1))]}"
  printf '       owner quote on record: "%s"\n' "$quote"
  printf '       reason: %s\n' "$reason"
  printf '       terminal link signed into audit chain @ %s (head %s…)\n' "$(git_ref)" "$(chain_head | cut -c1-12)"
  printf '       `bones next`/`approve`/`build` now refuse. `bones back -s <n> -r ...` can revive it if the owner reverses.\n'
}

cmd_note() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock
  local text="${*:-}"
  [ -n "$text" ] || die "note needs text"
  journal note "$text"
  printf 'bones: noted.\n'
}

cmd_log() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  bootstrap
  printf '== bones audit trail: %s ==\n\n-- gate records --\n' "$(state_get name)"
  local n=1 gf
  while [ "$n" -le "$NSTAGES" ]; do
    gf="$(gate_file "$n")"
    if [ -f "$gf" ]; then printf '[stage %s]\n' "$n"; sed 's/^/  /' "$gf"; fi
    n=$((n+1))
  done
  if [ -d "$BONES_DIR/gates/archive" ]; then
    printf '\n-- archived (superseded by back) --\n'
    find "$BONES_DIR/gates/archive" -type f -name '*.ok' | sort | while IFS= read -r f; do
      printf '[%s]\n' "${f#"$BONES_DIR"/gates/archive/}"; sed 's/^/  /' "$f"
    done
  fi
  if [ -f "$BONES_DIR/ledger" ]; then
    printf '\n-- chain (ledger) --\n'
    local seq ts ev st gt git prev rel csha hash
    while IFS='|' read -r seq ts ev st gt git prev rel csha hash; do
      [ -z "${seq:-}" ] && continue
      printf '  %2s  %-8s stage %-2s  %-16s %s…\n' "$seq" "$ev" "$st" "$git" "$(printf '%s' "$hash" | cut -c1-10)"
    done < "$BONES_DIR/ledger"
    if [ -d "$BONES_DIR/sigs" ]; then
      local nsig; nsig="$(ls "$BONES_DIR"/sigs/*.asc 2>/dev/null | wc -l | tr -d ' ')"
      [ "${nsig:-0}" -gt 0 ] && printf '  (%s GPG signature(s) on owner gates)\n' "$nsig"
    fi
  fi
  if [ -f "$BONES_DIR/journal.log" ]; then
    printf '\n-- journal --\n'; sed 's/^/  /' "$BONES_DIR/journal.log"
  fi
}

cmd_verify() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  bootstrap
  local ledger="$BONES_DIR/ledger"
  [ -f "$ledger" ] || die "no audit chain found (this pipeline predates verifiable audit — re-init to enable)"

  # Pass 1 — integrity: recompute each link's hash and check the prev-links form
  # one unbroken chain from genesis. Any edit/insert/delete/reorder is caught here.
  # Along the way, remember (by link position) the last signing link of every gate
  # path, the last regression per target stage and the last kill: pass 3 needs them.
  local prev="$GENESIS" n=0 seq ts ev st gt git p rel csha hash canon calc
  local -a sign_at sign_sha back_at
  local kill_at=0 kill_sha="" back_any=0 gi
  while IFS='|' read -r seq ts ev st gt git p rel csha hash; do
    [ -z "${seq:-}" ] && continue
    n=$((n+1))
    canon="$seq|$ts|$ev|$st|$gt|$git|$p|$rel|$csha"
    calc="$(printf '%s' "$canon" | sha_stdin)"
    if [ "$calc" != "$hash" ]; then
      printf 'bones: ✗ CHAIN BROKEN at link %s (seq %s, %s): record was altered.\n' "$n" "$seq" "$ev" >&2
      exit 1
    fi
    if [ "$p" != "$prev" ]; then
      printf 'bones: ✗ CHAIN BROKEN at link %s (seq %s): prev-link mismatch — a record was inserted, deleted, or reordered.\n' "$n" "$seq" >&2
      exit 1
    fi
    prev="$hash"
    case "$ev" in
      approve|build|step)
        gi="${rel#gates/}"; gi="${gi%%-*}"
        case "$gi" in ''|*[!0-9]*) ;; *)
          if [ "$gi" -ge 1 ] && [ "$gi" -le "$NSTAGES" ] && [ "$rel" = "$(gate_rel "$gi")" ]; then
            sign_at[$gi]="$n"; sign_sha[$gi]="$csha"
          fi ;;
        esac ;;
      back)
        case "$st" in ''|*[!0-9]*) ;; *) back_at[$st]="$n" ;; esac
        back_any="$n" ;;
      kill) kill_at="$n"; kill_sha="$csha" ;;
    esac
  done < "$ledger"
  [ "$n" -gt 0 ] || die "audit chain is empty"

  # Pass 2 — head consistency: state.json must point at the ledger's final link.
  local head; head="$(chain_head)"
  if [ "$head" != "$prev" ]; then
    printf 'bones: ✗ CHAIN BROKEN: state head (%s…) != ledger head (%s…) — ledger truncated or state edited.\n' \
      "$(printf '%s' "$head" | cut -c1-12)" "$(printf '%s' "$prev" | cut -c1-12)" >&2
    exit 1
  fi

  # Pass 3 — gates: every live gate file must match what was signed, must not have
  # been revoked by a later `back` (restoring an archived record is a forgery), and
  # every stage BEFORE the current one must hold such a gate — otherwise the stage
  # in state.json was edited to skip gates. (Last signing link per path wins, so
  # back+redo is handled.)
  local cur; cur="$(state_get stage)"
  case "$cur" in ''|*[!0-9]*) printf 'bones: ✗ state.json has no valid stage ("%s") — state edited or corrupt.\n' "$cur" >&2; exit 1 ;; esac
  local i gf rel2 live revoked=0
  for i in $(seq 1 "$NSTAGES"); do
    [ "${back_at[$i]:-0}" -gt "$revoked" ] && revoked="${back_at[$i]}"   # backs to stage <= i revoke gate i
    gf="$(gate_file "$i")"; rel2="$(gate_rel "$i")"
    if [ ! -f "$gf" ]; then
      if [ "$i" -lt "$cur" ]; then
        printf 'bones: ✗ pipeline is at stage %s but stage %s (%s) has no gate record — stages were skipped (state.json edited) or a gate record was deleted.\n' "$cur" "$i" "${STAGE_KEYS[$((i-1))]}" >&2
        exit 1
      fi
      continue
    fi
    if [ -z "${sign_at[$i]:-}" ]; then
      # A gate file with no chain link = the classic forgery (`touch …-promote.ok`).
      printf 'bones: ✗ gate file %s exists but was NEVER signed into the chain — forged or corrupt.\n' "$rel2" >&2
      exit 1
    fi
    if [ "${sign_at[$i]}" -lt "$revoked" ]; then
      printf 'bones: ✗ gate file %s was revoked by a later `bones back` but is live again — restored from the archive, not re-approved.\n' "$rel2" >&2
      exit 1
    fi
    live="$(sha_of "$gf")"
    if [ "${sign_sha[$i]}" != "$live" ]; then
      printf 'bones: ✗ gate file %s was MODIFIED after signing (live content != chain signature).\n' "$rel2" >&2
      exit 1
    fi
  done
  # The kill record: the chain alone decides whether the pipeline is killed (a kill
  # link not followed by a revive), and state.json + killed.ok must agree with it.
  local chain_killed=0; [ "$kill_at" -gt "$back_any" ] && chain_killed=1
  if [ "$chain_killed" -eq 1 ] && ! is_killed; then
    printf 'bones: ✗ the chain records a KILL that was never revived, but state.json says "%s" — state edited.\n' "$(state_get status)" >&2; exit 1
  fi
  if [ "$chain_killed" -eq 0 ] && is_killed; then
    printf 'bones: ✗ state.json says killed but the chain holds no live kill link — state edited.\n' >&2; exit 1
  fi
  if [ -f "$BONES_DIR/killed.ok" ]; then
    if [ "$kill_at" -eq 0 ]; then
      printf 'bones: ✗ killed.ok exists but was NEVER signed into the chain — forged or corrupt.\n' >&2; exit 1
    fi
    if [ "$chain_killed" -eq 0 ]; then
      printf 'bones: ✗ killed.ok was revoked by a later `bones back` but is live again — restored from the archive.\n' >&2; exit 1
    fi
    if [ "$kill_sha" != "$(sha_of "$BONES_DIR/killed.ok")" ]; then
      printf 'bones: ✗ killed.ok was MODIFIED after signing (live content != chain signature).\n' >&2; exit 1
    fi
  elif [ "$chain_killed" -eq 1 ]; then
    printf 'bones: ✗ the chain records a KILL but killed.ok is missing — kill record deleted.\n' >&2; exit 1
  fi

  # Pass 4 — signatures (optional): any GPG-signed owner head must still validate.
  local signed=0 asc h dtmp
  if [ -d "$BONES_DIR/sigs" ]; then
    if command -v gpg >/dev/null 2>&1; then
      for asc in "$BONES_DIR"/sigs/*.asc; do
        [ -e "$asc" ] || continue
        h="$(basename "$asc" .asc)"
        grep -q "|$h$" "$ledger" || { printf 'bones: ✗ signature for a head (%s…) that is not in the chain.\n' "$(printf '%s' "$h" | cut -c1-12)" >&2; exit 1; }
        dtmp="$(mktemp)"; printf '%s' "$h" > "$dtmp"
        if ! gpg --verify "$asc" "$dtmp" >/dev/null 2>&1; then
          rm -f "$dtmp"; printf 'bones: ✗ INVALID GPG signature on head %s…\n' "$(printf '%s' "$h" | cut -c1-12)" >&2; exit 1
        fi
        rm -f "$dtmp"; signed=$((signed+1))
      done
    else
      signed="$(ls "$BONES_DIR"/sigs/*.asc 2>/dev/null | wc -l | tr -d ' ')"
      [ "$signed" -gt 0 ] && printf 'bones: • %s signature(s) present but gpg is missing — cannot verify them here.\n' "$signed" >&2
    fi
  fi

  # Pass 5 — git anchor: every version of the ledger committed to git (by `bones
  # seal` or by hand) must be a prefix of the live ledger. The chain is append-only,
  # so this catches a full, consistent rewrite of .bones/ after it was sealed — the
  # one attack the hashes alone can't see. A commit that deleted the ledger marks an
  # explicit restart (`bones reset -f` + commit): versions before it are not compared.
  local in_git=0 sealed=0 restart="" c ctmp csize
  if command -v git >/dev/null 2>&1 && git -C "$BONES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    in_git=1
    ctmp="$(mktemp)"
    for c in $(git -C "$BONES_DIR" log --format=%H -- ledger 2>/dev/null); do
      if ! git -C "$BONES_DIR" show "$c:./ledger" > "$ctmp" 2>/dev/null; then
        restart="$c"; break
      fi
      csize="$(wc -c < "$ctmp" | tr -d ' ')"
      if ! head -c "$csize" "$ledger" | cmp -s - "$ctmp"; then
        rm -f "$ctmp"
        printf 'bones: ✗ CHAIN REWRITTEN: the ledger sealed in git commit %s is not a prefix of the live one — .bones/ was rewritten or truncated after it was sealed (see `git log -p -- .bones/ledger`).\n' "$(printf '%s' "$c" | cut -c1-12)" >&2
        exit 1
      fi
      sealed=$((sealed+1))
    done
    rm -f "$ctmp"
  fi

  printf 'bones: ✓ CHAIN VERIFIED — %s links intact and in order; head %s…\n' "$n" "$(printf '%s' "$prev" | cut -c1-12)"
  printf '       every gate record is unaltered, and every live gate file matches its signature.\n'
  if [ "$signed" -gt 0 ]; then printf '       %s owner gate(s) carry a valid GPG signature.\n' "$signed"; fi
  if [ "$sealed" -gt 0 ]; then
    printf '       ⚓ anchored: %s sealed version(s) in git history, each a prefix of the live chain.\n' "$sealed"
  elif [ "$in_git" -eq 1 ]; then
    printf '       • not sealed yet — `bones seal` commits the chain so git history can catch a full rewrite.\n'
  fi
  [ -n "$restart" ] && printf '       ↻ chain restarted at git commit %s (an earlier sealed ledger was removed there).\n' "$(printf '%s' "$restart" | cut -c1-12)"
  if chain_unanchored; then
    printf '       ⚠ UNANCHORED: no link is bound to a git commit, so the chain is\n'
    printf '         tamper-evident but not externally anchored against a full rewrite.\n'
    printf '         Run inside a git repo and `bones seal` to anchor it in git history.\n'
  fi
  is_killed && printf '       ☠ pipeline status: KILLED (stopped by owner decision).\n'
  return 0
}

cmd_stats() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  bootstrap
  local jl="$BONES_DIR/journal.log"
  [ -f "$jl" ] || die "no journal yet — nothing to summarize"
  local -a t_secs t_count
  local backs=0 back_list="" ts ev rest st s
  while IFS='|' read -r ts ev rest; do
    ev="$(printf '%s' "$ev" | tr -d '[:space:]')"
    case "$ev" in
      timing)
        st="$(printf '%s' "$rest" | sed -nE 's/.*stage ([0-9]+).*/\1/p')"
        s="$(printf '%s' "$rest" | sed -nE 's/.*\(([0-9]+)s\)[[:space:]]*$/\1/p')"
        if [ -n "$st" ] && [ -n "$s" ]; then
          t_secs[$st]=$(( ${t_secs[$st]:-0} + s )); t_count[$st]=$(( ${t_count[$st]:-0} + 1 ))
        fi ;;
      back)
        backs=$((backs+1))
        st="$(printf '%s' "$rest" | sed -nE 's/.*-> ([0-9]+).*/\1/p')"
        [ -n "$st" ] && back_list="$back_list $st" ;;
    esac
  done < "$jl"

  printf '== bones stats: %s ==\n\n' "$(state_get name)"
  printf '  %-3s %-34s %8s  %5s\n' "#" "stage" "time" "runs"
  local i title sec cnt total=0
  for i in $(seq 1 "$NSTAGES"); do
    sec="${t_secs[$i]:-0}"; cnt="${t_count[$i]:-0}"; total=$((total+sec))
    title="${STAGE_TITLES[$((i-1))]}"
    printf '  %-3s %-34s %8s  %5s\n' "$i" "$(printf '%.34s' "$title")" "$(human_dur "$sec")" "${cnt}×"
  done
  printf '  %-3s %-34s %8s\n' "" "— total measured —" "$(human_dur "$total")"
  local elapsed; elapsed="$(elapsed_since "$(state_get created)" 2>/dev/null)"
  [ -n "$elapsed" ] && printf '\n  wall-clock since init : %s\n' "$(human_dur "$elapsed")"
  printf '  regressions (back)    : %s%s\n' "$backs" "${back_list:+  → to stages$back_list}"
}

cmd_config() {
  BONES_DIR="${BONES_DIR:-$(find_bones 2>/dev/null)}"
  load_config
  printf '== bones config ==\n'
  printf '  owner     %s\n' "$OWNER"
  printf '  template  %s\n' "$TEMPLATE"
  printf '  reviewer  %s\n' "$REVIEWER"
  printf '  sign      %s\n' "$SIGN"
  printf '\n  sources (last wins): defaults'
  [ -f "$HOME/.bonesrc" ] && printf ' → ~/.bonesrc'
  [ -n "${BONES_DIR:-}" ] && [ -f "$BONES_DIR/config" ] && printf ' → .bones/config'
  printf ' → env(BONES_*)\n'
}

cmd_doctor() {
  load_config
  printf '== bones doctor ==\n'
  if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
    printf '  ✓ sha256 tool present (the audit chain needs it)\n'
  else printf '  ✗ no shasum/sha256sum — the chain cannot be hashed\n'; fi
  if command -v git >/dev/null 2>&1; then
    printf '  ✓ git binary present\n'
    # If we're inside a pipeline, report whether ITS target is a repo — that's what
    # actually anchors the chain and enables `seal`, not merely the git binary.
    local _bd _tgt
    if _bd="$(find_bones 2>/dev/null)"; then
      _tgt="$(json_get "$_bd/state.json" target 2>/dev/null)"; [ -n "$_tgt" ] || _tgt="$PWD"
      if git -C "$_tgt" rev-parse --git-dir >/dev/null 2>&1; then
        printf '  ✓ target is a git repo — commit binding + `bones seal` available\n'
      else
        printf '  ⚠ target is NOT a git repo — chain records "no-git"; `bones seal` unavailable (`git init` to anchor)\n'
      fi
    fi
  else
    printf '  • git not found — links record "no-git" (chain still works, but unanchored)\n'
  fi
  command -v jq >/dev/null 2>&1 && printf '  ✓ jq — robust JSON\n' \
    || printf '  • jq not found — using the grep/sed fallback parser\n'
  { [ -f "$LOOP_SH" ] || [ -x "$LOOP_SH" ]; } && printf '  ✓ loop.sh — %s\n' "$LOOP_SH" \
    || printf '  ✗ loop.sh missing at %s — auto/build gate cannot run\n' "$LOOP_SH"
  [ -d "$TEMPLATES_DIR" ] && printf '  ✓ templates — %s\n' "$(ls "$TEMPLATES_DIR" 2>/dev/null | sed 's/\.tsv$//' | tr '\n' ' ')" \
    || printf '  • no templates dir — built-in "code" still works\n'
  if [ "$SIGN" = "1" ]; then
    command -v gpg >/dev/null 2>&1 && printf '  ✓ gpg — signing enabled and available\n' \
      || printf '  ✗ sign=1 but gpg not found — owner gates cannot be signed\n'
  else printf '  • signing off (set sign=1 in ~/.bonesrc to enable GPG)\n'; fi
  command -v bones >/dev/null 2>&1 && printf '  ✓ bones on PATH — %s\n' "$(command -v bones)" \
    || printf '  • bones not on PATH — symlink scripts/bones.sh into ~/.local/bin\n'
}

cmd_seal() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  acquire_lock; bootstrap
  local target; target="$(state_get target)"
  command -v git >/dev/null 2>&1 || die "seal needs git — it commits .bones/ as the external anchor"
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || die "target is not a git repo — nothing to anchor into"
  # Never anchor a broken chain. (subshell so verify's internal exit can't kill us)
  ( cmd_verify ) >/dev/null 2>&1 || die "chain does not verify — refusing to seal a broken audit trail (run 'bones verify')"
  git -C "$target" add "$BONES_DIR" >/dev/null 2>&1
  if git -C "$target" diff --cached --quiet -- "$BONES_DIR" 2>/dev/null; then
    if git -C "$target" check-ignore -q "$BONES_DIR" 2>/dev/null; then
      die ".bones/ is gitignored — cannot anchor it. Un-ignore it (the audit trail is meant to be committed)."
    fi
    printf 'bones: nothing new to seal — .bones/ is already committed at this state.\n'; return 0
  fi
  local head; head="$(chain_head)"
  git -C "$target" commit -q -m "bones: seal audit chain @ ${head:0:12} (stage $(state_get stage)/$NSTAGES)" -- "$BONES_DIR" \
    && printf 'bones: ✓ sealed — .bones/ committed. Head %s… is now anchored in git history.\n' "${head:0:12}" \
    || die "git commit failed"
}

cmd_reset() {
  BONES_DIR="$(find_bones)" || die "no .bones here"
  local force=0; [ "${1:-}" = "-f" ] && force=1
  if [ "$force" -ne 1 ]; then die "this deletes $BONES_DIR — re-run 'bones reset -f' to confirm"; fi
  acquire_lock
  local was_sealed=0; ledger_sealed_in_head "$BONES_DIR" && was_sealed=1
  rm -rf "$BONES_DIR"; printf 'bones: reset (removed %s)\n' "$BONES_DIR"
  if [ "$was_sealed" -eq 1 ]; then
    printf '       .bones/ was sealed in git: commit its removal (e.g. `git add -A .bones && git commit -m "bones: reset"`)\n'
    printf '       before the next init, so `verify` sees an explicit restart instead of a rewrite.\n'
  fi
}

usage() {
  cat <<EOF
bones $BONES_VERSION — the gated, tamper-evident ship pipeline

Usage: bones <command> [options]

Pipeline
  init -t <dir> [-n name] [-T template] [-H] [-f]
                         start a pipeline in <dir> (-T code|ops|research, -H strict owner gates)
  status                 where am I, which gate is open, what to do next (default command)
  approve [-q "quote"] [-e file]... "note"
                         satisfy the current owner/agent gate (owner gates need -q)
  build -c "cmd" [-s spec] [-r rubric] [-R auto|codex|gemini|none] [-n max]
                         the auto gate: passes only when the acceptance command exits 0
  next                   advance one stage, only if the current gate is satisfied
  back -s <n> -r "why"   go back to stage <n> (archives gates, keeps the audit trail)
  kill -q "quote" -r "why"
                         the owner stops the build (terminal; 'back' can revive it)

Audit
  note "text"            journal an observation
  log                    full audit trail: gates, archive, chain, journal
  verify                 recompute the tamper-evident chain (exit 1 if anything was faked)
  seal                   verify, then git-commit .bones/ (the external anchor)
  stats                  per-stage time and regressions

Setup
  config                 show resolved settings (~/.bonesrc -> .bones/config -> BONES_* env)
  doctor                 check the environment (sha256, git, loop.sh, gpg, PATH)
  reset -f               delete .bones/
  version                print the version

Docs: https://github.com/xvibessss/bones
EOF
}

# --- dispatch --------------------------------------------------------------
BONES_DIR="${BONES_DIR:-}"
sub="${1:-status}"; shift || true
case "$sub" in
  init)    cmd_init "$@" ;;
  status)  cmd_status ;;
  approve) cmd_approve "$@" ;;
  build)   cmd_build "$@" ;;
  next)    cmd_next ;;
  back)    cmd_back "$@" ;;
  kill)    cmd_kill "$@" ;;
  note)    cmd_note "$@" ;;
  log)     cmd_log ;;
  verify)  cmd_verify ;;
  seal)    cmd_seal ;;
  stats)   cmd_stats ;;
  config)  cmd_config ;;
  doctor)  cmd_doctor ;;
  reset)   cmd_reset "$@" ;;
  version|--version|-v) printf 'bones %s\n' "$BONES_VERSION" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $sub — run 'bones help'" ;;
esac
