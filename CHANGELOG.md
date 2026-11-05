# Changelog

All notable changes to bones. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## 1.3.0 — 2026-11-05

### Security
- `bones verify` re-hashes every evidence file attached with `approve -e`. A
  spec edited after the owner signed it, or an evidence file that disappeared, is
  reported as **evidence drift** — a warning by default, a failure with the new
  `bones verify --strict`. Until now the sha256 was recorded but never checked.

### Changed
- `approve -e` records evidence inside the project relative to its root (not to
  the directory approve ran from), so `verify` finds it from anywhere and on any
  clone. Evidence must be a regular file: a directory used to be accepted with an
  empty hash.

### Fixed
- A project that was **moved or cloned elsewhere** (a CI checkout, a teammate's
  machine) kept using the absolute path recorded at `init`: evidence was looked
  up — and `build`, `seal` and the git binding ran — at the old location. bones
  now always works on the directory that holds `.bones/`.

### Added
- `bones status --json`: stage, current gate, lifecycle status and chain head
  for scripts, agents and CI.
- Completions for `status --json` and `verify --strict`; the README's CI job
  uses `verify --strict` (75 checks).

## 1.2.0 — 2026-11-05

### Security
- `bones verify` now checks the chain against **git history**: every version of
  the ledger committed by `bones seal` (or by hand) must be a prefix of the live
  ledger. A full, internally consistent rewrite of `.bones/` after a seal — the
  one attack the hashes alone couldn't see — now fails with `CHAIN REWRITTEN`.
- `bones init -f` refuses to replace a sealed pipeline. Starting over is
  explicit: `bones reset -f`, commit the removal, `bones init`; `verify` then
  reports the restart and its commit.

### Added
- `verify` reports how many sealed versions anchor the chain, or that it isn't
  sealed yet.
- README: "Verify in CI" — a ready-to-copy GitHub Actions job for projects that
  use bones.
- Tests for seal, explicit restarts, strict mode, config files, `log` and
  `stats` (63 checks).

## 1.1.0 — 2026-11-05

### Security
- `bones verify` now catches **stages skipped by editing `state.json`**: every
  stage before the current one must hold a signed gate record. Before, setting
  `"stage": 9` by hand skipped every gate and the chain still verified.
- `bones verify` now catches a **gate resurrected from the archive** after
  `bones back` (it was revoked by a later regression link but looked valid).
- `bones verify` now catches a **kill undone by editing `state.json`** (instead of
  `bones back`) and a **deleted kill record**: the chain alone decides whether a
  pipeline is killed, and `state.json` must agree.

### Fixed
- `reviewer` from `~/.bonesrc` / `BONES_REVIEWER` is now actually passed to the
  build loop (an explicit `-R` still wins). It was documented but ignored.
- The build loop runs reviewer CLIs non-interactively (`codex exec`,
  `gemini -p`) so a failing check can't hang on an interactive session.
- The jq-less JSON fallback no longer truncates values containing commas (e.g. a
  target path like `~/work/a,b`); `jq` no longer drops `false` values.
- `init` refuses a name or path containing `"`, `\` or a newline, which would
  have produced an unreadable `state.json`.
- Messages no longer hard-code "10 stages" or "build-loop" for custom templates.

### Added
- `bones help` prints real usage (it used to dump every comment in the script).
- `./install.sh --uninstall`.
- CI: the suite also runs without `jq`, and `shellcheck` gates every PR.
- `SECURITY.md`, threat model in the README, `help`/`version` and `build -n` in
  shell completions.

### Changed
- Docs and messages use neutral pronouns and no longer refer to a single owner.
- Strict mode is described accurately: it requires an interactive terminal on
  stdin, which a non-interactive agent shell doesn't have.

## 1.0.0 — 2026-11-02

First public release: the 10-stage gated pipeline, owner/agent/auto/step gates,
the hash-chained ledger with `verify` and `seal`, optional GPG signing, `kill`,
templates (`code`, `ops`, `research`), config, `doctor`, completions and the
Claude Code skills.

