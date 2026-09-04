---
name: ship-pipeline
description: "the owner's 9.5 ship-pipeline — the 10-stage discipline for taking a big build from raw idea to shipped-and-operating, described in prose. Use when the owner says 'ship-pipeline', 'run the pipeline', or wants the reference for what each stage does and why. For MECHANICAL enforcement of the gates (refuses to skip a stage), use bones-pipeline instead — this skill is the reference it drives."
---

# ship-pipeline — the 9.5 build discipline (reference)

Ten stages from raw idea to a thing that runs in production and teaches you
something. This file explains **what each stage does and why**. To run it with
the gates *mechanically enforced* (a state machine that refuses to advance past
an unsatisfied gate, and distinguishes owner vs. agent vs. auto vs. step gates),
use the **`bones-pipeline`** skill — `bones` is the driver; this is
the map it follows. `scripts/loop.sh` here is the acceptance-gated build loop
that `bones build` invokes at stage 5.

## The 10 stages

**1. Brainstorm + prompt interrogation** *(agent gate)*
Widen before you narrow. Interrogate the request until the real problem is sharp:
what does "done" mean, who is it for, what's explicitly out of scope, what's the
riskiest assumption. Tighten the prompt/brief until it could brief someone else.

**2. Kill-or-commit** *(OWNER gate — the owner's call)*
The brutal ≤30-minute check: given what stage 1 surfaced, is this worth building
*now*? Present the honest case (cost, risk, opportunity cost) and let the owner either
kill it or commit. Killing here is a win — it's the cheapest place to stop.

**3. Spec sign-off** *(OWNER gate — the owner's call)*
Write the spec as a self-contained HTML doc: scope, non-goals, acceptance
criteria, the shape of the solution. Acceptance criteria must be **executable or
checkable** — they become stage 5's gate. the owner signs off the spec before code.

**4. Council / second-pass critique** *(agent gate)*
Adversarial read of the spec *before* building. Run it past a council (multiple
perspectives / models) or a deliberate second-pass critique: where will this
break, what's underspecified, what's over-built. A rejection here → `bones back
-s 3` to fix the spec. Cheap to fix on paper.

**5. Build loop (acceptance gate)** *(AUTO gate — machine-verified)*
Build against the spec, then prove it with the acceptance command. Driven by
`loop.sh`: it runs your acceptance check and the gate opens **only on exit 0**.
```
bones build -c "<acceptance_cmd>" -s <spec.html> [-r <rubric>] [-R auto|codex|gemini]
```
No sign-off substitutes for a green check here. If a reviewer CLI is available,
loop.sh iterates it against the failing check; otherwise you fix and re-run.

**6. Adversarial review + security** *(agent gate)*
Now that it works, attack it. Code review for correctness/reuse/simplification,
then a security pass (secrets, injection, authz, unsafe deserialization, supply
chain). Findings that reopen the build → `bones back -s 5`. Attach the review
file as evidence (`approve -e <file>`).

**7. Staging validation** *(agent gate)*
Exercise the real thing in a staging/non-live environment: end-to-end run, the
actual click-path a user takes, and a comparison against the bar you set (a
competitor / prior version / the spec's success criteria) — all green **before**
anything goes live. Attach the staging log or screenshot as evidence.

**8. Promote + production smoke test** *(OWNER gate — the owner's call)*
The irreversible step: promote to production, then run a smoke test against prod.
the owner gives the explicit go; a redirect that changes scope is `bones back`, not an
approve. This is an owner gate precisely because it's the point of no easy return.

**9. Present** *(step)*
Show the owner what shipped: what it does, what changed, how to use it, where the
audit trail lives. No gate — but leave the record.

**10. Operate + learn** *(OWNER gate — the owner's call)*
It's live. Watch it, then decide with the owner: double-down, park, or kill. Capture
what the build taught you (in `bones note`), so the next pipeline starts smarter.

## Going backward is normal

Council rejects the spec → back to 3. Review reopens the build → back to 5. A
promote redirect → back to whatever it invalidates. `bones back` archives the
cleared gate records (never deletes) and demands a reason — regressions stay part
of the story.

## Non-code operations

Maps cleanly to ops runs (outreach, research, content): stage 5's "acceptance
command" is a `check.sh` that verifies the deliverable; "staging" is the
deliverable validated but not sent/published; "promote" is the live/irreversible
action — which is why it's an owner gate.
