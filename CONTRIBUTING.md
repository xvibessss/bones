# Contributing to bones

Thanks for helping. bones is small on purpose: zero-dependency bash, one script,
one test suite. Changes that keep it that way are the easiest to merge.

## Before you open a pull request

1. Run the tests and keep them green:

   ```bash
   bash scripts/test.sh
   ```

2. If you change behaviour, add a check to `scripts/test.sh` that fails without
   your change and passes with it.
3. No new runtime dependencies. `jq` and `gpg` stay optional; anything else
   needs a strong reason in the PR description.
4. Keep it portable: the suite must pass on both macOS (BSD tools, bash 3.2)
   and Linux (GNU tools), with and without `jq` (`BONES_NO_JQ=1 bash scripts/test.sh`).
5. Keep `shellcheck` clean:

   ```bash
   shellcheck -S warning scripts/*.sh install.sh completions/bones.bash
   ```

CI runs all of this on both platforms for every pull request.

## Reporting a bug

Open an issue with the command you ran, what you expected, what happened, and
the output of `bones doctor`.

## Reporting a way to fake a gate

The point of bones is that a gate cannot be skipped or forged without the
audit chain noticing. If you find a way to do it (tampering the ledger, a
`.ok` file or a signature without `bones verify` catching it), please do not
open a public issue. Use GitHub's private vulnerability reporting instead:
the **Security** tab of this repository → **Report a vulnerability**. See
[SECURITY.md](SECURITY.md) for what's in scope.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
