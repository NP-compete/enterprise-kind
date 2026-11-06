#!/usr/bin/env bash
# Mints a login token for the Headlamp console.
#   scripts/token.sh          -> cluster-admin, 8h
#   scripts/token.sh viewer   -> read-only, 8h
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

role="${1:-admin}"
case "${role}" in
  admin)  sa=headlamp-login-admin ;;
  viewer) sa=headlamp-login-viewer ;;
  *) die "usage: token.sh [admin|viewer]" ;;
esac

tok="$(kc -n headlamp create token "${sa}" --duration=8h)"
printf '%s\n' "${tok}"
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "${tok}" | pbcopy
  warn "copied to clipboard (${sa}, valid 8h)"
fi
