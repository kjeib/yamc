# chrome/desktop-entries.sh - install desktop entries that route through the wrapper
#
# Sourced by chrome/setup and chrome/upgrade. Not executable on its own.
#
# Why this exists:
#
# The wrapper at /usr/local/bin/google-chrome only takes effect for callers that
# resolve "google-chrome" through PATH. The .desktop files that google-chrome-stable
# installs into /usr/share/applications/ hardcode:
#
#   Exec=/usr/bin/google-chrome-stable %U
#
# so every launch through the desktop-entry layer bypasses the wrapper entirely.
# That layer is how essentially all URL opening happens: xdg-open, exo-open, gio,
# and xdg-desktop-portal -- the last being the *only* route out of a confined snap
# such as Ubuntu's Thunderbird, which cannot even see /usr/local/bin.
#
# The result on an NFS-home system is Chrome starting with no --user-data-dir: it
# lands on ~/.config/google-chrome (NFS, frequently holding a stale SingletonLock
# from another host) instead of the local profile the running browser is using, so
# the URL cannot be handed to the existing window and a second browser starts.
#
# We fix it by shadowing Chrome's two desktop IDs from /usr/local/share/applications,
# which precedes /usr/share in XDG_DATA_DIRS and is not touched by package upgrades.
# Both IDs are needed: com.google.Chrome.desktop is the one the portal resolves, and
# google-chrome.desktop is the one that carries legacy default-browser settings.

# Render the template to $2, with NoDisplay=true when $1 is "hidden".
# com.google.Chrome.desktop sets NoDisplay so the app menu shows only one Chrome.
chrome_render_desktop_entry() {
  local mode="$1" dest="$2"

  if [ "$mode" = "hidden" ]; then
    sed 's|@NODISPLAY@|NoDisplay=true|' "$MOD_DIR/google-chrome.desktop" > "$dest"
  else
    sed '/@NODISPLAY@/d' "$MOD_DIR/google-chrome.desktop" > "$dest"
  fi
}

# Install both shadowing entries. Idempotent: only writes when content differs.
install_chrome_desktop_entries() {
  local appdir="/usr/local/share/applications"
  local template="$MOD_DIR/google-chrome.desktop"
  local changed=0

  if [ ! -f "$template" ]; then
    echo "  ! No google-chrome.desktop template in module; skipping desktop entries"
    return 0
  fi

  echo ""
  echo "Installing Chrome desktop entries (route GUI/URL launches through wrapper)..."

  mkdir -p "$appdir"

  # id:mode pairs -- com.google.Chrome is the ID xdg-desktop-portal resolves
  local entry id mode dest staged
  for entry in "google-chrome.desktop:visible" "com.google.Chrome.desktop:hidden"; do
    id="${entry%:*}"
    mode="${entry#*:}"
    dest="$appdir/$id"
    staged="$MOD_TMP/$id.staged"

    chrome_render_desktop_entry "$mode" "$staged"

    if [ -f "$dest" ] && cmp -s "$staged" "$dest"; then
      echo "  ✓ $id already up to date"
    else
      cp "$staged" "$dest"
      chmod 644 "$dest"
      echo "  ✓ $id installed: $dest"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$appdir" 2>/dev/null || true
    echo "  ✓ Desktop database updated"
  fi

  echo "  Note: these shadow /usr/share/applications/ and survive Chrome upgrades."
}
