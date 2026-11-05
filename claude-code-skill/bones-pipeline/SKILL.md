---
name: bones-pipeline
description: "Enforced version of the 10-stage ship-pipeline — a state-machine that MECHANICALLY enforces every gate instead of trusting an agent to follow prose. Use whenever the user runs /bonespipeline, or says 'bones pipeline', 'enforced pipeline', 'gated build', 'run the pipeline properly', 'don't let me skip steps', or kicks off a big build where the gates must actually hold (kill-or-commit, spec sign-off, council, acceptance-verified build loop, review+security, staging-before-promote, prod smoke, operate/learn). Prefer this over plain ship-pipeline when discipline matters — it refuses to advance past an unsatisfied gate. Not for small one-file edits or quick questions."
---

# bones-pipeline — the ship-pipeline, mechanically gated

Same 10-stage pipeline as `ship-pipeline`, but the gates are **enforced by a state
machine**, not by an agent remembering to honor prose. `bones` tracks the
current stage in `.bones/state.json` and **refuses to advance past a gate until it's
satisfied** — and it distinguishes WHO may satisfy each gate.

Read `ship-pipeline/SKILL.md` for what each stage *does* and why. This skill is the
**driver** that makes those stages happen in order, gated.

## Gate types — who holds the pen

| Type | Meaning | Satisfied by |
|------|---------|--------------|
| **owner** | the owner's call, not yours | `approve -q "<their verbatim words>" "<note>"` — the script refuses without a quote |
| **agent** | your judgment call | `approve [-e <evidence_file>]... "<substantive note>"` — thin notes ("approved", "done") are rejected |
| **auto** | machine-verified | `bones build …` → loop.sh real exit 0. `approve` is rejected here |
| **step** | no gate | `next` advances and records the step |

## The owner-gate protocol (the point of this skill)

Stages 2 (kill-or-commit), 3 (spec), 8 (promote), 10 (operate) are **the owner's
decisions**. Before approving one you MUST:

1. Present the stage's output and **ask the owner directly** (AskUserQuestion, or
   their message in the conversation).
2. **Wait for their actual reply.** No reply = gate stays open. Say what's blocked and stop.
3. Record their exact words: `bones approve -q "<verbatim>" "<what was decided>"`.

The quote is **verbatim or nothing** — it goes on the permanent record and the owner can
read it back. A fabricated or paraphrased quote is a falsified audit record, strictly
worse than a skipped gate.

**Commit *or* kill.** `approve` means COMMIT — the build goes on. If the owner's decision at
kill-or-commit (stage 2) or operate (stage 10) is to **STOP**, that is not an `approve`
and not a `note` — it is `bones kill -q "<their verbatim words>" -r "<why>"`. Kill writes a
terminal link into the audit chain and sets the pipeline's status to **killed**, so a
stopped build reads as *stopped*, never as a gate left hanging for an unreachable owner.
`next`/`approve`/`build` then refuse; if the owner later reverses, `bones back -s <n> -r "…"`
revives it. Recording a kill as a plain note leaves the pipeline looking merely blocked — don't.

**Rationalizations that don't fly** (each observed or predictable in real runs):

| Excuse | Reality |
|--------|---------|
| "the owner said 'figure it out' / 'go ahead' at kickoff" | One authorization ≠ four sign-offs. Ask at each owner gate. |
| "They're busy and this is low-stakes" | Then the gate stays open. Blocked-and-honest beats shipped-and-unauthorized. |
| "I know what they'd say" | A prediction is not a quote. Ask. |
| "They redirected me, that's basically approval" | A redirect that changes scope = `bones back` to the stage it invalidates, not an approve. |
| "The work is genuinely done, the gate is a formality" | Done-ness is what *agent/auto* gates check. Owner gates check *consent*. |

For ironclad runs: `init -H` (strict mode) makes owner gates require an interactive
terminal — the owner types the approve themselves; a non-interactive agent shell cannot.

## How to drive it

`bones` — run from anywhere inside the target (finds `.bones/` by walking up).

```
bones init -t <dir> [-n name] [-T template] [-H]   # start; -T code|ops|research; -H strict
bones status [--json]                       # where am I, which gate is open, what to do (--json: parse it)
bones approve [-q "<quote>"] [-e <file>]... "<note>"   # satisfy current owner/agent gate
bones build -c "<acceptance_cmd>" -s <spec.html> [-r rubric] [-R auto|codex|gemini]
                                               # the AUTO gate; passes only on loop.sh exit 0
bones next                                  # advance IF gate satisfied (else refuses)
bones kill -q "<owner quote>" -r "<reason>" # owner STOPS the build: terminal chain link, status=killed
bones back -s <stage> -r "<reason>"         # regress (archives gate records, keeps audit); revives a killed pipeline
bones note "<text>"                         # journal an observation mid-stage
bones log                                   # full audit trail: gates + archive + journal
bones verify [--strict]                     # recompute the chain + re-hash -e evidence (--strict: drift fails)
bones seal                                  # verify, then git-commit .bones/ (later verifies check it only grew)
bones stats                                 # per-stage time + regressions from the journal
bones config                                # show resolved owner/template/reviewer/sign
bones doctor                                # environment checks (sha, git, loop.sh, gpg, PATH)
bones reset -f                              # wipe state
```

Typical flow each stage: **do the work (using the relevant skills per ship-pipeline)
→ satisfy the gate → `bones next`.** `status` always says which of those you're on.

## Before you init, and what stage 1 must nail

- **Name the subject first.** "Dogfood it" / "run the pipeline" is not a build target.
  Stage 1 (brainstorm) must produce a **named deliverable** — the one concrete slice this
  run will ship — before you spend an owner gate on it.
- **Check it isn't already built.** Before committing at stage 2, verify the slice isn't
  already done (grep the code, run it). The gate's pressure to "produce something" is how
  fake work sneaks in; a stage-1 note should state *what's missing*, not just what's wanted.
- **Init in a git repo when you can.** On a non-git target the chain is still
  tamper-evident but **unanchored** — its commit-binding is empty and `bones seal` is
  unavailable. `init` and `doctor` warn about this; `git init` first for a fully
  anchored trail.
- **No test harness (e.g. a static site)?** The AUTO gate (stage 5) needs an acceptance
  command that exits 0. Copy `scripts/acceptance-example.sh` into the target as `check.sh`,
  add real assertions for the slice, then `bones build -c "./check.sh"`. An empty check
  that always passes proves nothing — put at least one concrete assertion in it.

## Templates — code, ops, research

`init -T <template>` picks the stage set; the pipeline freezes it into
`.bones/pipeline.tsv`, so it stays self-describing even if templates change.
`code` is the 10 stages above. `ops` (outreach/content) and `research`
(investigations) map the same shape — an **auto** gate for "produce/gather with a
check script", an **owner** gate for the live/irreversible "publish/send". `build`
runs on whichever stage is the auto gate, not a fixed number. Add your own
template as a `key<TAB>title<TAB>gate<TAB>evidence` TSV under `templates/`.

## Config — make it yours (and shareable)

Owner name and defaults come from `~/.bonesrc` (global) then `.bones/config`
(per-pipeline), overridable by `BONES_OWNER` / `BONES_TEMPLATE` / `BONES_REVIEWER`
/ `BONES_SIGN`. Keys: `owner` (default "the owner"), `template`, `reviewer`, `sign`.
`bones config` prints what resolved. So anyone can drop a `~/.bonesrc` and the
owner-gate prompts speak their name.

## Concurrency & robustness

State-mutating commands take a `.bones/.lock` (atomic `mkdir`, steals a dead
holder's lock) so two runs can't interleave a ledger append. `state.json` is
written atomically (temp + rename). `bones doctor` reports the environment.

## The 10 stages

| # | Stage | Gate | # | Stage | Gate |
|---|-------|------|---|-------|------|
| 1 | Brainstorm + interrogation | agent | 6 | Adversarial review + security | agent |
| 2 | Kill-or-commit | **owner** | 7 | Staging validation | agent |
| 3 | Spec sign-off | **owner** | 8 | Promote + prod smoke | **owner** |
| 4 | Council / critique | agent | 9 | Present | step |
| 5 | Build loop | **auto** | 10 | Operate + learn | **owner** |

Agent gates on evidence-heavy stages (3, 6, 7) warn loudly when approved without
`-e` — attach the spec, review file, staging log/screenshot; bones records path +
sha256 so the artifact is pinned to the sign-off.

The two "or-kill" stages are **2** (kill-or-commit) and **10** (operate: double-down /
park / **kill**). At either, stopping is `bones kill` (see the owner-gate protocol),
not `approve` — that keeps a killed build distinct from a merely-open gate.

## Going backward is normal

Council rejects the spec → `back -s 3`. Review findings reopen the build →
`back -s 5`. The owner redirects promote → `back` to whatever stage their redirect
invalidates. `back` archives the cleared gate records (never deletes) and demands a
reason, so regressions are part of the story, not erased from it.

## Non-code operations

bones works for ops (outreach runs, research pipelines, content pushes) too — map the
stages: "build loop" = produce the deliverable with an executable check script as the
acceptance command (`-c "./check.sh"`), "staging" = the deliverable validated but not
live/sent, "promote" = the live/irreversible action (send, publish, CRM write) —
which is exactly why promote is an **owner** gate.

## Red flags — stop and re-read the owner-gate protocol

- You're typing `approve -q` and the owner hasn't said anything this stage
- You're summarizing what the owner "effectively" said
- You're rushing gates because the session is long or the work feels done
- You marked promote approved when what actually happened was a redirect
- The owner decided to **stop** and you reached for `note` or just left the gate open —
  that's a `bones kill -q "<verbatim>" -r "<why>"`, so the record says *killed*, not *pending*

## The audit chain is tamper-evident

Every satisfied gate is signed into `.bones/ledger` as a hash-chained link (git
style): each link embeds the sha256 of the previous one, of the gate record
(note + owner quote + evidence), and of the repo's commit at sign-time. So the
audit trail isn't just honest — it's **verifiable**:

```
bones verify
```

recomputes the whole chain and FAILS on any edit, insertion, deletion,
truncation, forged (`touch`-ed) or resurrected gate file, or a stage skipped
by editing `state.json`. Run it before you trust a
`.bones/` you didn't watch being built, and after every `back`. Commit `.bones/`
with the build (`bones seal`): `verify` then checks that every sealed version of
the ledger is a prefix of the live one, so even a consistent rewrite is caught.
Seal after each owner gate — what is sealed can no longer be quietly redone.

With `sign=1` in config, owner-gate consent is additionally **GPG-signed**: the
chain head at each owner approval gets a detached signature under `.bones/sigs/`,
and `verify` validates them — turning "a text says the owner consented" into a
cryptographic signature they can't repudiate. Best-effort: no gpg → the gate is
still recorded, just unsigned (with a warning).

Never fake a gate. The `.bones/` dir is the audit trail — and now it can prove
it wasn't tampered with — short of a rewrite of `.bones/` before it was ever
sealed, which is why you seal early and, for owner consent, GPG-sign.
