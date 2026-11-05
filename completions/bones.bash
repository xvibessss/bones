# bash completion for bones. Enable with:
#   source /path/to/bones/completions/bones.bash
# compgen output is split on purpose (mapfile is not in bash 3.2).
# shellcheck disable=SC2207
_bones_complete() {
  local cur subs
  cur="${COMP_WORDS[COMP_CWORD]}"
  subs="init status approve build next back kill note log verify seal stats config doctor reset help version"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$subs" -- "$cur") )
    return
  fi
  case "${COMP_WORDS[1]}" in
    init)    COMPREPLY=( $(compgen -W "-t -n -T -H -f" -- "$cur") ) ;;
    approve) COMPREPLY=( $(compgen -W "-q -e" -- "$cur") ) ;;
    build)   COMPREPLY=( $(compgen -W "-c -s -r -R -n" -- "$cur") ) ;;
    back)    COMPREPLY=( $(compgen -W "-s -r" -- "$cur") ) ;;
    kill)    COMPREPLY=( $(compgen -W "-q -r" -- "$cur") ) ;;
    reset)   COMPREPLY=( $(compgen -W "-f" -- "$cur") ) ;;
    status)  COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
    verify)  COMPREPLY=( $(compgen -W "--strict" -- "$cur") ) ;;
  esac
}
complete -F _bones_complete bones bones.sh
