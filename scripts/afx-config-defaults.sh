# afx-config-defaults.sh: neutral built-in values for afx_config_get (afx-platform.sh) when no config file is in effect, so the
# common case needs no node start-up. Sourced, never executed. Must equal DEFAULTS in afx-config.mjs (afx-config.test.mjs checks).
# The core knows no organisation. On a machine that has the private AFX preset (afx-config-defaults.afx.sh, next to this file)
# it is sourced last and replaces _afx_config_default with that tenant's values; AFX_NO_PRESET=1 skips it.
_afx_config_default() {
  case "$1" in
    org) echo "" ;;
    hubRepo) echo "" ;;
    extraOrgs) echo "" ;;
    clonesRootMac) echo "~/afx/clones" ;;
    clonesRootWindows) echo "~/afx/clones" ;;
    registryFile) echo "~/.afx/allforx-projects.json" ;;
    brand) echo "AFX CLI" ;;
    quickstartDoc) echo "" ;;
    enabledModules) echo "all" ;;
    policyPacks) echo "" ;;
    *) return 1 ;;
  esac
}
_AFX_DEFAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -z "${AFX_NO_PRESET:-}" ] && [ -f "$_AFX_DEFAULTS_DIR/afx-config-defaults.afx.sh" ]; then . "$_AFX_DEFAULTS_DIR/afx-config-defaults.afx.sh"; fi
