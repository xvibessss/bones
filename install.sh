#!/usr/bin/env bash
#
# install.sh — put `bones` on your PATH. Zero-dependency; nothing is compiled.
# Re-runnable and non-destructive (updates the symlink in place).
# `./install.sh --uninstall` removes it again.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/scripts/bones.sh"

# ./install.sh --uninstall — remove the `bones` symlink(s) that point into this repo.
if [ "${1:-}" = "--uninstall" ]; then
  removed=0
  for d in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    if [ -L "$d/bones" ] && [ "$(readlink "$d/bones")" = "$SRC" ]; then
      rm -f "$d/bones" && echo "✓ removed $d/bones" && removed=1
    fi
  done
  [ "$removed" -eq 1 ] || echo "install: no bones symlink pointing at $SRC found — nothing to remove."
  exit 0
fi
case "${1:-}" in
  "") ;;
  -h|--help) echo "usage: ./install.sh [--uninstall]"; exit 0 ;;
  *) echo "install: unknown option '$1' (usage: ./install.sh [--uninstall])" >&2; exit 2 ;;
esac
[ -f "$SRC" ] || { echo "install: can't find $SRC — run this from the repo root." >&2; exit 1; }
chmod +x "$REPO/scripts/"*.sh 2>/dev/null || true

# Pick a bin dir that is on PATH and writable without sudo.
pick_bindir() {
  local d
  for d in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    case ":$PATH:" in *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { printf '%s' "$d"; return 0; } ;; esac
  done
  # none on PATH yet — create ~/.local/bin
  mkdir -p "$HOME/.local/bin"; printf '%s' "$HOME/.local/bin"
}
BIN="$(pick_bindir)"
ln -sf "$SRC" "$BIN/bones"
echo "✓ linked  $BIN/bones → $SRC"

# Is BIN actually on PATH in this shell?
case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) cat <<EOF

⚠  $BIN is not on your PATH yet. Add this to your shell profile, then restart it:

     export PATH="$BIN:\$PATH"
EOF
  ;;
esac

cat <<EOF

Next steps
  bones doctor                 # verify your environment (sha, git, loop.sh, gpg)
  cp $REPO/bonesrc.example ~/.bonesrc   # then set owner = your name
  bones init -t .              # start a pipeline in the current project

Shell completion (optional)
  bash:  echo 'source $REPO/completions/bones.bash' >> ~/.bashrc
  zsh :  echo 'fpath=($REPO/completions \$fpath); autoload -U compinit; compinit' >> ~/.zshrc

Use with Claude Code (optional)
  ln -s $REPO/claude-code-skill/bones-pipeline ~/.claude/skills/bones-pipeline
  ln -s $REPO/claude-code-skill/ship-pipeline  ~/.claude/skills/ship-pipeline
  # then say "bones pipeline" or run /bonespipeline in a session
EOF
