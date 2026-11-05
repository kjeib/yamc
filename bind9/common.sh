#!/bin/bash
# bind9/common.sh - Shared helpers for bind9 remote scripts
#
# Sourced by setup, deploy and edit:  source "$MOD_DIR/common.sh"

# list_local_zones <named.local>
# Print "<zone> <file>" for each zone block that declares a file.
list_local_zones() {
  awk '
    /^[[:space:]]*zone[[:space:]]+"/ {
      match($0, /"[^"]+"/); zone = substr($0, RSTART + 1, RLENGTH - 2)
    }
    /^[[:space:]]*file[[:space:]]+"/ && zone != "" {
      match($0, /"[^"]+"/); print zone, substr($0, RSTART + 1, RLENGTH - 2)
      zone = ""
    }
  ' "$1"
}

# check_source_zones
# Validate every zone declared in $RES_DIR/named.local against its source
# file in $RES_DIR/zones/ (matched by basename of the declared path).
# Runs before anything is installed, so a failure leaves the live server
# untouched. Returns non-zero if any zone is missing or fails named-checkzone.
check_source_zones() {
  local named_local="$RES_DIR/named.local"
  local zone path src errors=0

  [ -f "$named_local" ] || return 0

  echo "Checking zones in named.local..."
  while read -r zone path; do
    [ -n "$zone" ] || continue
    src="$RES_DIR/zones/$(basename "$path")"
    if [ ! -f "$src" ]; then
      echo "  ERROR: $zone: source file not found: $src"
      errors=$((errors + 1))
    elif ! named-checkzone -q "$zone" "$src"; then
      echo "  ERROR: $zone: named-checkzone failed:"
      named-checkzone "$zone" "$src" | sed 's/^/    /' || true
      errors=$((errors + 1))
    else
      echo "  OK: $zone ($(basename "$src"))"
    fi
  done < <(list_local_zones "$named_local")

  if [ "$errors" -gt 0 ]; then
    echo "ERROR: $errors zone(s) failed validation. Nothing was deployed."
    return 1
  fi
}
