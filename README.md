# bones — the gated, tamper-evident ship pipeline

[![CI](https://github.com/xvibessss/bones/actions/workflows/ci.yml/badge.svg)](https://github.com/xvibessss/bones/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![bash](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

`bones` turns a checklist you *could* skip into a **state machine that refuses to
advance** past an unsatisfied gate — and records every gate into an append-only,
hash-chained ledger you can later **prove** wasn't faked.

It drives a 10-stage pipeline from raw idea to shipped-and-operating, with the
decisions that matter (commit, spec, promote, operate) reserved as the owner's call.

```
brainstorm → kill-or-commit → spec → council → build → review → staging → promote → present → operate
   agent        OWNER        OWNER   agent    AUTO    agent     agent      OWNER     step     OWNER
```

It's **zero-dependency bash** — no build, no runtime, no packages. Works on macOS
and Linux.

---

## Download & install

```bash
git clone https://github.com/xvibessss/bones.git
cd bones
./install.sh
```

`install.sh` symlinks the `bones` command onto your `PATH` (`~/.local/bin` by
default) — it touches nothing else and is safe to re-run. `./install.sh --uninstall`
removes the link. If that dir isn't on
your `PATH` yet, the script tells you the one line to add to your shell profile.

Then check your environment and make it yours:

```bash
bones doctor                      # sha256, git, loop.sh, gpg, PATH — all green?
cp bonesrc.example ~/.bonesrc     # then edit: owner = your name
```

<details>
<summary>Manual install (no script)</summary>

```bash
ln -s "$PWD/scripts/bones.sh" ~/.local/bin/bones   # any dir on your PATH
```
</details>

**Requirements:** `bash`, plus the usual `shasum`/`sha256sum`, `git` (optional but
recommended — it anchors the audit chain), and `jq` (optional; falls back without
it). `gpg` only if you want signed owner consent.

---

## Quickstart

```bash
cd my-project
bones init -t .                 # start a pipeline here
bones status                    # what's the open gate, and what do I do?
# ... do stage 1's work ...
bones approve "scope + non-goals pinned, riskiest assumption named"
bones next                      # advances ONLY because the gate is satisfied
```

Every stage is the same rhythm: **do the work → satisfy the gate → `bones next`.**
`bones status` always tells you which of those you're on.

---

## The four gate types — who holds the pen

|  | Gate | Satisfied by |
|--|------|--------------|
| **owner** | the owner's call (kill-or-commit, spec, promote, operate) | `approve -q "<their verbatim words>" "<note>"` — no quote, no pass |
| **agent** | a judgment call | `approve [-e <evidence>]... "<substantive note>"` — thin notes rejected |
| **auto** | machine-verified (the build) | `bones build -c "<cmd>" -s <spec>` → passes only on the check's exit 0 |
| **step** | no gate | `next` advances and records it |

- **Owner gates** need *verbatim* consent: `bones approve -q "ship it" "committed"`.
  Strict mode (`init -H`) additionally requires an interactive terminal, so an
  agent running commands through a non-interactive shell can't satisfy them.
- **The build gate** opens only on a green acceptance check. No sign-off substitutes.
- **Going back** is normal: `bones back -s 3 -r "council reopened the spec"`. It
  archives the cleared gates (never deletes) and keeps the audit trail.

---

## Why it's trustworthy: the audit chain

Every satisfied gate appends a link to `.bones/ledger`. Each link hashes its own
record **plus the previous link's hash** (git-style) **plus the git commit** it
was signed at. So the trail isn't just honest — it's verifiable:

```bash
bones verify
```

exits non-zero on any of these:

- a ledger link edited, inserted, deleted, reordered or truncated;
- a gate record (`gates/*.ok`) edited after it was signed;
- a forged gate file (`touch .bones/gates/8-promote.ok`) that was never signed;
- a gate revoked by `bones back` and then copied back out of the archive;
- stages skipped by editing `"stage"` in `state.json`, or a passed gate deleted;
- a kill undone by editing `state.json` instead of `bones back`, or its record deleted;
- a chain rewritten or truncated after `bones seal` committed it — even one that
  is internally consistent (see below);
- (with `sign=1`) a GPG signature on owner consent that no longer validates.

**Seal as you go.** `bones seal` verifies the chain, then commits `.bones/` to the
target repo. From then on `verify` reads every version of the ledger in git
history and requires each one to be a prefix of the live ledger: the chain only
ever grows, so anything else is a rewrite.

Starting over in a repo that holds a sealed pipeline is explicit, so it can't be
confused with a rewrite: `bones reset -f`, commit the removal of `.bones/`, then
`bones init`. `verify` reports the restart and the commit it happened at.

### Threat model — what the chain does and doesn't prove

The chain is hashed, not keyed: anyone with write access to `.bones/` *and* the
patience to recompute every hash can produce a new chain that is consistent on
its own. What stops that is outside the ledger: the versions already sealed in
git history (`verify` checks the live chain extends each of them) and, for owner
consent, GPG signatures made with a key the agent doesn't hold. In short:

| Guarantee | Needs |
|---|---|
| Accidental or casual edits, skipped stages, forged/resurrected gates are caught | nothing — `bones verify` |
| A full, consistent rewrite of `.bones/` is caught | `bones seal` — `verify` compares every sealed version |
| …even if the agent also rewrites git history | the seals pushed to a protected branch (no force-push) |
| "The owner consented" is non-repudiable | `sign=1` with the owner's own GPG key |
| The agent can't type the owner's approval itself | `init -H` and the agent has no interactive TTY |

bones keeps an honest agent honest and makes a dishonest one leave evidence. It
is not a sandbox: it can't stop an agent with full shell access from lying in the
*content* of a note — which is why owner gates demand verbatim quotes and agent
gates take `-e` evidence files pinned by sha256.

### Verify in CI

Make a broken or rewritten chain fail the build of the project that uses bones.
Add this workflow to **that** project (not to bones itself):

```yaml
# .github/workflows/bones.yml
name: bones
on: [push, pull_request]
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history: verify compares every sealed ledger
      - name: Verify the bones audit chain
        run: |
          git clone --quiet --depth 1 --branch v1.2.0 https://github.com/xvibessss/bones "$RUNNER_TEMP/bones"
          bash "$RUNNER_TEMP/bones/scripts/bones.sh" verify
```

`verify` finds `.bones/` by walking up from the working directory; if your
pipeline lives in a subdirectory, add `working-directory: <that dir>` to the
step. Pinning a tag (`--branch v1.2.0`) keeps the verifier itself from changing
under you.

---

## Commands

| | |
|---|---|
| `init -t <dir> [-n name] [-T template] [-H]` | start; `-T` picks the stage set, `-H` = strict owner gates |
| `status` | where am I, which gate is open, time in stage |
| `approve [-q quote] [-e file]... "note"` | satisfy an owner/agent gate |
| `build -c "cmd" -s spec [-r rubric] [-R reviewer]` | the auto gate — passes on exit 0 |
| `next` / `back -s N -r "why"` | advance (if satisfied) / regress (keeps audit) |
| `kill -q "quote" -r "why"` | owner STOPS the build — terminal chain link, status=killed |
| `note "text"` · `log` | journal an observation · full audit trail |
| `verify` | recompute the tamper-evident chain |
| `seal` | verify, then git-commit `.bones/` — later `verify`s check the chain only grew |
| `stats` | per-stage time + regressions |
| `config` · `doctor` | resolved settings · environment checks |
| `reset -f` | wipe `.bones/` |
| `help` · `version` | usage · version |

---

## Templates

`code` (software), `ops` (outreach/content), `research` (investigations). Pick one
with `init -T <name>`. Each keeps the same shape — an auto gate for "produce with a
check", an owner gate for the live/irreversible action. `init` freezes the choice
into `.bones/pipeline.tsv`, so a pipeline stays self-describing even if the
templates change later. Add your own TSV under [`templates/`](templates/).

---

## Use with Claude Code (optional)

`bones` is a plain CLI and needs nothing else. But if you use
[Claude Code](https://claude.com/claude-code), this repo also ships the skill that
lets Claude *drive* the pipeline for you while honoring every gate:

```bash
ln -s "$PWD/claude-code-skill/bones-pipeline" ~/.claude/skills/bones-pipeline
ln -s "$PWD/claude-code-skill/ship-pipeline"  ~/.claude/skills/ship-pipeline
```

Then in a session say **"bones pipeline"** (or run **`/bonespipeline <goal>`**) and
Claude runs the stages, stopping at each owner gate to ask *you* for the verbatim
decision it can't make on your behalf.

---

## Shell completion (optional)

```bash
# bash
echo 'source "'"$PWD"'/completions/bones.bash"' >> ~/.bashrc
# zsh
echo 'fpath=('"$PWD"'/completions $fpath); autoload -U compinit; compinit' >> ~/.zshrc
```

---

## What lands in your project

```
.bones/
├── state.json      current stage + chain head
├── pipeline.tsv    this pipeline's stage list (self-describing)
├── ledger          the append-only hash chain
├── config          per-pipeline overrides (optional)
├── gates/*.ok      human-readable gate records (+ archive/ for regressions)
├── sigs/*.asc      GPG signatures on owner gates (if sign=1)
└── journal.log     chronological trail incl. per-stage durations
```

Commit `.bones/` alongside your work — it's the audit trail.

---

## Tests

```bash
bash scripts/test.sh
```

63 checks (60 when `gpg` isn't installed): happy path, gate refusals, the build
gate, twelve tamper attacks on the ledger, gate files, `state.json` and sealed
history, back+redo, seal and explicit restarts, strict mode, concurrency,
templates, config files, kill (stop/refusals/tamper/revive), log and stats, the
non-git warning, the jq-less fallback parser, and GPG signing. CI runs it on Linux and
macOS (bash 3.2), with and without `jq`, plus `shellcheck`.

---

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Found a way to fake a gate or break the audit chain? Please report it privately
first, as described there.

---

## License

[MIT](LICENSE).
