#!/usr/bin/env bash
#
# lib/config.sh — thin `yq` (mikefarah) wrappers over the container-dev YAML
# config. Sourced by bin/create.sh, bin/list.sh, bin/delete.sh.
#
# Callers must set PROJECT_DIR and CONFIG_DIR before sourcing this file.
# See docs/plan-network-policy.md for the schema design.

CFG_REPO_FILE="$PROJECT_DIR/config/container-dev.yaml"
CFG_USER_FILE="$CONFIG_DIR/config.yaml"
CFG_MERGED_FILE=""

# Merge repo defaults + user overrides into one document, once per process.
cfg_load() {
  [[ -n "$CFG_MERGED_FILE" && -f "$CFG_MERGED_FILE" ]] && return 0

  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: 'yq' is required (https://github.com/mikefarah/yq)." >&2
    echo "  Install with: brew install yq" >&2
    exit 1
  fi
  if [[ ! -f "$CFG_REPO_FILE" ]]; then
    echo "ERROR: missing $CFG_REPO_FILE" >&2
    exit 1
  fi

  CFG_MERGED_FILE="$(mktemp -t container-dev-config)"
  if [[ -f "$CFG_USER_FILE" ]]; then
    if ! yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' \
        "$CFG_REPO_FILE" "$CFG_USER_FILE" > "$CFG_MERGED_FILE" 2>/dev/null; then
      echo "ERROR: failed to merge $CFG_USER_FILE onto $CFG_REPO_FILE (malformed YAML?)" >&2
      exit 1
    fi
  else
    cp "$CFG_REPO_FILE" "$CFG_MERGED_FILE"
  fi
}

# cfg_get <yq-path> [default] — scalar accessor.
cfg_get() {
  cfg_load
  local val
  val=$(yq eval "${1} // \"\"" "$CFG_MERGED_FILE" 2>/dev/null)
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "${2:-}"
  else
    echo "$val"
  fi
}

# cfg_list <yq-path> — sequence accessor, one element per line (empty if absent).
cfg_list() {
  cfg_load
  yq eval "${1} // [] | .[]" "$CFG_MERGED_FILE" 2>/dev/null
}

# cfg_has <yq-path> — true if the path resolves to a non-null value.
cfg_has() {
  cfg_load
  local val
  val=$(yq eval "${1} // \"\"" "$CFG_MERGED_FILE" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]]
}

# cfg_expand <string> — expands $HOME, $CONFIG_DIR, $WORKSPACE literals.
cfg_expand() {
  local s="$1"
  s="${s//\$HOME/$HOME}"
  s="${s//\$CONFIG_DIR/$CONFIG_DIR}"
  s="${s//\$WORKSPACE/${WORKSPACE:-}}"
  echo "$s"
}

cfg_validate() {
  cfg_load
  if ! yq eval '.' "$CFG_MERGED_FILE" >/dev/null 2>&1; then
    echo "ERROR: malformed config YAML" >&2
    exit 1
  fi
  cfg_has '.profiles' || { echo "ERROR: config has no 'profiles:' section" >&2; exit 1; }
}

cfg_profile_names()   { cfg_list '.profiles | keys'; }
cfg_profile_exists()  { cfg_has ".profiles.\"$1\""; }
cfg_profile_port()    { cfg_get ".profiles.\"$1\".port" "2299"; }
cfg_profile_backend() { cfg_get ".profiles.\"$1\".backend" "claude"; }
cfg_profile_network() { cfg_get ".profiles.\"$1\".network" "$(cfg_get '.defaults.network' 'standard')"; }
cfg_profile_mount_groups() { cfg_list ".profiles.\"$1\".mounts"; }

# cfg_mount_group <group-name> — expanded "src:dst[:mode]" lines from mounts.<group>.
cfg_mount_group() {
  cfg_list ".mounts.\"$1\"" | while IFS= read -r line; do
    [[ -n "$line" ]] && cfg_expand "$line"
  done
}

# cfg_profile_mounts <profile> — expanded mount lines from all of a profile's mount groups.
cfg_profile_mounts() {
  local profile="$1" group
  while IFS= read -r group; do
    [[ -n "$group" ]] && cfg_mount_group "$group"
  done < <(cfg_profile_mount_groups "$profile")
}

# cfg_auth_mounts <auth-type> — expanded mount lines from auth_mounts.<type>.
cfg_auth_mounts() {
  cfg_list ".auth_mounts.\"$1\"" | while IFS= read -r line; do
    [[ -n "$line" ]] && cfg_expand "$line"
  done
}

# cfg_resource <size> — echoes "cpus mem"; exits non-zero on unknown size.
cfg_resource() {
  local size="$1" cpus mem
  cpus=$(cfg_get ".defaults.resources.\"$size\".cpus")
  mem=$(cfg_get ".defaults.resources.\"$size\".mem")
  if [[ -z "$cpus" || -z "$mem" ]]; then
    echo "ERROR: unknown size '$size' (see defaults.resources in config/container-dev.yaml)" >&2
    exit 1
  fi
  echo "$cpus $mem"
}

cfg_auth_force() { cfg_get '.auth.force'; }

# cfg_auth_detect — walks auth.detect in declared order, first match wins.
cfg_auth_detect() {
  local n i=0
  n=$(cfg_get '.auth.detect | length' '0')
  while [[ "$i" -lt "$n" ]]; do
    local type when_file when_env
    type=$(cfg_get ".auth.detect[$i].type")
    when_file=$(cfg_get ".auth.detect[$i].when_file")
    when_env=$(cfg_get ".auth.detect[$i].when_env")
    if [[ -n "$when_file" ]]; then
      [[ -f "$(cfg_expand "$when_file")" ]] && { echo "$type"; return; }
    elif [[ -n "$when_env" ]]; then
      [[ -n "${!when_env:-}" ]] && { echo "$type"; return; }
    else
      echo "$type"; return
    fi
    ((i++))
  done
  echo "web"
}

# Named configs (profiles.<profile>.configs.<name>) — the opencode-style
# multi-backend selector. NOT used for cline, whose --config is dynamic
# (arbitrary host directories, not an enumerable YAML set).
cfg_profile_config_exists()  { cfg_has ".profiles.\"$1\".configs.\"$2\""; }
cfg_profile_config_auth()    { cfg_get ".profiles.\"$1\".configs.\"$2\".auth"; }
cfg_profile_config_network() { cfg_get ".profiles.\"$1\".configs.\"$2\".network" "$(cfg_profile_network "$1")"; }
cfg_profile_config_mount_groups() { cfg_list ".profiles.\"$1\".configs.\"$2\".mounts"; }

# cfg_profile_config_mounts <profile> <config> — expanded mount lines from the
# config's own mount groups (falls back to the profile's if the config declares none).
cfg_profile_config_mounts() {
  local profile="$1" config="$2" group had_any=false
  while IFS= read -r group; do
    [[ -n "$group" ]] || continue
    had_any=true
    cfg_mount_group "$group"
  done < <(cfg_profile_config_mount_groups "$profile" "$config")
  [[ "$had_any" == false ]] && cfg_profile_mounts "$profile"
  return 0
}
