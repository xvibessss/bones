# bones — the gated, tamper-evident ship pipeline

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
default) — it touches nothing else and is safe to re-run. If that dir isn't on
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
  Strict mode (`init -H`) additionally requires a real terminal, so an automated
  agent physically can't satisfy them.
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

fails on any edit, insertion, deletion, truncation, or a forged (`touch`-ed) gate
file. With `sign=1` in your config, owner consent is additionally GPG-signed and
verified. **Commit `.bones/` with your build** (`bones seal` does this) so git
history anchors the chain against a full rewrite.

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
| `seal` | git-commit `.bones/` (the external anchor; verifies first) |
| `stats` | per-stage time + regressions |
| `config` · `doctor` | resolved settings · environment checks |
| `reset -f` | wipe `.bones/` |

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

36 checks: happy path, gate refusals, the six tamper attacks, back+redo,
concurrency, templates, config, kill (stop/refusals/tamper/revive), the non-git
warning + unanchored-chain flag, and (when `gpg` is present) signing.

---

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Found a way to fake a gate or break the audit chain? Please report it privately
first, as described there.

---

## License

[MIT](LICENSE).
