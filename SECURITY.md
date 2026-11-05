# Security policy

bones exists so that a gate can't be skipped or forged without `bones verify`
noticing. A way around that is a security bug, even if it "only" fakes an audit
trail.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
the **Security** tab of this repository → **Report a vulnerability**
(<https://github.com/xvibessss/bones/security/advisories/new>).

Include the commands that reproduce it (ideally a short script that builds a
pipeline, tampers with it, and shows `bones verify` still passing), and the
output of `bones version` and `bones doctor`.

You'll get an answer within a week. Fixes ship with a regression check in
`scripts/test.sh` and credit in the changelog unless you'd rather stay anonymous.

## In scope

- Faking, resurrecting or skipping a gate without `bones verify` failing.
- Editing, inserting, deleting or reordering ledger links undetected.
- Getting an owner gate past strict mode (`init -H`) from a non-interactive shell.
- Forging or replaying a GPG signature that `verify` accepts.
- Any way a crafted `.bones/` directory makes `bones` run unintended commands.

## Out of scope (documented limits)

- A full, consistent rewrite of `.bones/` *before it was ever sealed*, or a
  rewrite of git history itself, by someone with write access: the chain is
  hashed, not keyed. Sealing early (`bones seal`), pushing the seals to a
  protected branch and GPG signing are the defences; see "Threat model" in the
  README. (A rewrite *after* a seal that `verify` misses **is** in scope.)
- An agent with full shell access writing a false *note*: bones records what it
  is told, pins evidence files by sha256, and demands verbatim owner quotes.
- `bones build` runs the acceptance command you give it, by design.

## Supported versions

Only the latest release on `main` gets fixes.
