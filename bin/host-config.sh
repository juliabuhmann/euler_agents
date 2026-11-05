# shellcheck shell=bash
# Sourced on the HOST by bin/hpc-agent-run and bin/hpc-agent-submit, so both resolve
# configuration the same way. Not executable on purpose.
#
# Expects REPO_DIR. Sets SETTINGS to a temp file holding the merged configuration:
#   config/settings.json, shallow-updated by config/settings.local.json, plus the cluster
#   profile config/sites/<site>.json (updated by "site_overrides") under the key "site_cfg".
# Defines _setting (expression over the settings, as s) and _site (over the site, as s).

SETTINGS=$(mktemp)
trap 'rm -f "$SETTINGS"' EXIT
python3 - "$REPO_DIR/config" "$SETTINGS" <<'PY'
import json, os, sys
cfg, out = sys.argv[1], sys.argv[2]
s = json.load(open(os.path.join(cfg, "settings.json")))
local = os.path.join(cfg, "settings.local.json")
if os.path.exists(local):
    s.update(json.load(open(local)))
name = s.get("site") or "euler"
path = os.path.join(cfg, "sites", name + ".json")
if not os.path.exists(path):
    available = sorted(f[:-5] for f in os.listdir(os.path.join(cfg, "sites")) if f.endswith(".json"))
    sys.exit("ERROR: unknown site '%s' (no %s). Available: %s" % (name, path, ", ".join(available)))
site = json.load(open(path))
site.update(s.get("site_overrides") or {})
site["name"] = name
s["site_cfg"] = site
json.dump(s, open(out, "w"))
PY

_setting() {
    python3 -c "import json; s=json.load(open('$SETTINGS')); print($1)"
}

_site() {
    python3 -c "import json; s=json.load(open('$SETTINGS'))['site_cfg']; print($1)"
}

# Load the site's environment modules (e.g. a proxy, or the container runtime itself).
# A batch job does not always inherit the `module` function, so fall back to the usual
# Lmod / Environment Modules init scripts. Those are not written for `set -u`.
_load_site_modules() {
    local mods f
    mods=$(_site "' '.join(s.get('modules') or [])")
    [[ -n "$mods" ]] || return 0
    if ! type module >/dev/null 2>&1; then
        set +u
        for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/bash; do
            [[ -f "$f" ]] && { source "$f"; break; }
        done
        set -u
    fi
    if ! type module >/dev/null 2>&1; then
        echo "WARNING: no 'module' command; site modules not loaded: $mods" >&2
        return 0
    fi
    set +u
    # shellcheck disable=SC2086  # one word per module
    module load $mods || { set -u; echo "ERROR: 'module load $mods' failed" >&2; exit 1; }
    set -u
}
