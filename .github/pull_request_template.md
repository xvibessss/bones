## What and why

## How I tested it

- [ ] `bash scripts/test.sh` is green
- [ ] `shellcheck -S warning scripts/*.sh install.sh completions/bones.bash` is clean
- [ ] Behaviour changes come with a check in `scripts/test.sh` that fails without them
- [ ] No new runtime dependency
