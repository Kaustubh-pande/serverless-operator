#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091,SC1090
source "$(dirname "${BASH_SOURCE[0]}")/../lib/__sources__.bash"

root_dir="$(dirname "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")")"
index_dir="${root_dir}/olm-catalog/serverless-operator-index"

# ------------------------------------------------------------------------------
# Utilities
# ------------------------------------------------------------------------------
normalize_version() {
  local v="$1"
  v="${v#v}"
  v="${v#V}"
  v="${v%%[[:space:]]*}"
  printf "%s" "$v"
}

# Collect fallback candidates from processed_versions and existing index dirs.
collect_fallback_candidates() {
  local -n out_arr=$1
  shift
  local -a processed=("$@")
  declare -A seen=()

  for p in "${processed[@]}"; do
    p=$(normalize_version "$p")
    [[ -z "$p" ]] && continue
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      out_arr+=("$p")
    fi
  done

  for d in "${index_dir}"/v*/; do
    if [[ -d "$d" ]]; then
      local ver
      ver=$(basename "$d")
      ver="${ver#v}"
      ver=$(normalize_version "$ver")
      [[ -z "$ver" ]] && continue
      if [[ -z "${seen[$ver]:-}" ]]; then
        seen[$ver]=1
        out_arr+=("$ver")
      fi
    fi
  done
}

# Return the highest candidate < target, or empty
find_best_less_than() {
  local target="$1"; shift
  local -a candidates=("$@")
  local best=""
  for c in "${candidates[@]}"; do
    if versions.lt "$c" "$target"; then
      if [[ -z "$best" ]] || versions.gt "$c" "$best"; then
        best="$c"
      fi
    fi
  done
  printf "%s" "$best"
}

# Remove value from array (by value)
remove_from_array() {
  local val="$1"
  shift
  local -a arr=("$@")
  local -a out=()
  for e in "${arr[@]}"; do
    [[ "$e" == "$val" ]] && continue
    out+=("$e")
  done
  echo "${out[@]}"
}

# ------------------------------------------------------------------------------
# Copy & validate fallback
# ------------------------------------------------------------------------------
copy_catalog_from_previous() {
  local ocp_version="$1"
  local fallback_version="$2"

  ocp_version=$(normalize_version "$ocp_version")
  fallback_version=$(normalize_version "$fallback_version")

  logger.info "Copying catalog/template: fallback ${fallback_version} -> target ${ocp_version}"
  mkdir -p "${index_dir}/v${ocp_version}/catalog/serverless-operator"

  local src_catalog="${index_dir}/v${fallback_version}/catalog/serverless-operator/catalog.yaml"
  local src_template="${index_dir}/v${fallback_version}/catalog-template.yaml"
  local dst_catalog="${index_dir}/v${ocp_version}/catalog/serverless-operator/catalog.yaml"
  local dst_template="${index_dir}/v${ocp_version}/catalog-template.yaml"

  local copied_any=0

  if [[ -f "$src_catalog" ]]; then
    cp "$src_catalog" "$dst_catalog"
    copied_any=1
  else
    logger.warn "Source catalog.yaml missing in v${fallback_version}"
  fi

  if [[ -f "$src_template" ]]; then
    cp "$src_template" "$dst_template"
    copied_any=1
  else
    logger.warn "Source catalog-template.yaml missing in v${fallback_version}"
  fi

  # Validate the copied catalog.yaml minimally
  if [[ -f "$dst_catalog" ]]; then
    if ! yq read "$dst_catalog" 'entries' >/dev/null 2>&1; then
      logger.error "Copied catalog.yaml from v${fallback_version} to v${ocp_version} is invalid or missing expected 'entries' key"
      rm -f "$dst_catalog" "$dst_template" || true
      return 1
    fi
  else
    logger.error "No catalog.yaml copied for v${ocp_version} (fallback from v${fallback_version})."
    rm -f "$dst_template" || true
    return 1
  fi

  logger.info "Fallback copy successful: v${fallback_version} -> v${ocp_version}"
  return 0
}

# Attempt iterative fallback candidates until one succeeds.
attempt_fallback_for() {
  local ocp_version="$1"
  shift
  local processed_versions_arr=("$@")

  local -a candidates=()
  collect_fallback_candidates candidates "${processed_versions_arr[@]}"

  # Keep trying best candidate < ocp_version until none left
  while : ; do
    local best
    best=$(find_best_less_than "$ocp_version" "${candidates[@]}")
    if [[ -z "$best" ]]; then
      logger.error "No fallback candidates remain for OCP ${ocp_version}"
      return 1
    fi

    logger.info "Trying fallback candidate v${best} for OCP ${ocp_version}"
    if copy_catalog_from_previous "$ocp_version" "$best"; then
      return 0
    fi

    logger.warn "Fallback from v${best} failed — trying next candidate"
    # remove best and loop
    read -r -a candidates <<< "$(remove_from_array "$best" "${candidates[@]}")"
  done
}

# ------------------------------------------------------------------------------
# Channel management (kept robust & simple)
# ------------------------------------------------------------------------------
add_channel() {
  local catalog_template=${1?Pass catalog template path as arg[1]}
  local channel=${2:?Pass channel name as arg[2]}
  local version="${3:-$(metadata.get 'project.version')}"

  current_csv="serverless-operator.v${version}"
  major=$(versions.major "${version}")
  minor=$(versions.minor "${version}")
  micro=$(versions.micro "${version}")

  if [[ "$micro" == "0" ]]; then
    previous_version="${major}.$(( minor-1 )).${micro}"
  else
    previous_version="${major}.${minor}.0"
  fi

  catalog=$(mktemp catalog-XXX.json)
  channel_entry=$(yq read "${catalog_template}" "entries[name==${channel}]" 2>/dev/null || true)

  if [[ "${channel_entry}" == "" ]]; then
    copy_of_stable=$(yq read "${catalog_template}" "entries[name==stable]" 2>/dev/null || true)
    versioned_channel=$(echo "${copy_of_stable}" | yq write - name "${channel}")
    versioned_channel_json=$(echo "${versioned_channel}" | yq read - --tojson)

    yq read "${catalog_template}" --tojson --prettyPrint | \
      jq '.entries += ['"${versioned_channel_json}"']' | \
      yq read - --prettyPrint > "${catalog}"

    mv "${catalog}" "${catalog_template}"
  fi

  current_csv_entry=$(yq read "${catalog_template}" "entries[name==${channel}].entries[name==${current_csv}]" 2>/dev/null || true)

  should_add=0
  if [[ "${current_csv_entry}" == "" ]]; then
    replaces="serverless-operator.v${previous_version}"
    entry_with_same_replaces=$(yq read "${catalog_template}" "entries[name==${channel}].entries[replaces==${replaces}].name" 2>/dev/null || true)
    if [[ "${entry_with_same_replaces}" == "" ]]; then
      should_add=1
      cp "${catalog_template}" "${catalog}"
    else
      if versions.ge "${current_csv}" "${entry_with_same_replaces}"; then
        should_add=1
        yq delete "${catalog_template}" "entries[name==${channel}].entries[replaces==${replaces}]" > "${catalog}"
      fi
    fi

    if (( should_add )); then
      cat << EOF | yq write --inplace --script - "$catalog"
      - command: update
        path: entries[name==${channel}].entries[+]
        value:
          name: "serverless-operator.v${version}"
          replaces: "${replaces}"
          skipRange: "\u003e=${previous_version} \u003c${version}"
EOF
      mv "${catalog}" "${catalog_template}"

      add_bundle "${catalog_template}" "$(get_bundle_for_version "${version}")"
    fi
  fi
  rm -f "${catalog}" || true
}

add_bundle() {
  local bundle catalog_template sha
  catalog_template=${1?Pass catalog template path as arg[1]}
  bundle="${2:?Pass bundle as arg[2]}"

  sha=${bundle##*:}
  entry=$(yq read "${catalog_template}" --tojson --prettyPrint | jq '.entries[] | select(.schema=="olm.bundle") | select(.image|test("'${sha}'"))' 2>/dev/null || true)
  if [[ "${entry}" == "" ]]; then
    cat << EOF | yq write --inplace --script - "$catalog_template"
    - command: update
      path: entries[+]
      value:
        schema: "olm.bundle"
        image: "${bundle}"
EOF
  fi
}

# ------------------------------------------------------------------------------
# Dependency image upgrades (unchanged)
# ------------------------------------------------------------------------------
upgrade_service_mesh_proxy_image() {
  sm_proxy_image=$(yq r olm-catalog/serverless-operator/project.yaml 'dependencies.service_mesh_proxy')
  sm_proxy_image_stream=$(skopeo inspect --retry-times=10 --no-tags=true "docker://${sm_proxy_image}" | jq -r '.Labels.version')
  sm_proxy_image_stream=${sm_proxy_image_stream%.*}
  sm_proxy_image=$(latest_konflux_image_sha "${sm_proxy_image}" "${sm_proxy_image_stream}")
  yq w --inplace olm-catalog/serverless-operator/project.yaml 'dependencies.service_mesh_proxy' "${sm_proxy_image}"
}

upgrade_kube_rbac_proxy_image() {
  local image image_stream
  image=$(metadata.get 'dependencies.kube_rbac_proxy')
  image_stream=$(metadata.get 'requirements.ocpVersion.kube-rbac-proxy')
  image=$(latest_konflux_image_sha "${image}" "v${image_stream}")
  yq w --inplace olm-catalog/serverless-operator/project.yaml 'dependencies.kube_rbac_proxy' "${image}"
}

upgrade_dependencies_images() {
  if [[ -n "${REGISTRY_REDHAT_IO_USERNAME:-}" ]] || [[ -n "${REGISTRY_REDHAT_IO_PASSWORD:-}" ]]; then
    skopeo login registry.redhat.io -u "${REGISTRY_REDHAT_IO_USERNAME}" -p "${REGISTRY_REDHAT_IO_PASSWORD}"
  fi
  upgrade_service_mesh_proxy_image
  upgrade_kube_rbac_proxy_image
}

# ------------------------------------------------------------------------------
# Main catalog generation with robust fallback
# ------------------------------------------------------------------------------
generate_catalog() {
  local catalog_template catalog_tmp_dir
  local processed_versions=()

  if [[ -n "${REGISTRY_REDHAT_IO_USERNAME:-}" ]] || [[ -n "${REGISTRY_REDHAT_IO_PASSWORD:-}" ]]; then
    skopeo login registry.redhat.io -u "${REGISTRY_REDHAT_IO_USERNAME}" -p "${REGISTRY_REDHAT_IO_PASSWORD}"
  fi

  default_serverless_operator_images

  while IFS=$'\n' read -r ocp_version; do
    ocp_version=$(normalize_version "$ocp_version")
    logger.info "Generating catalog for OCP ${ocp_version}"

    # --- index existence check ---
    if ! skopeo inspect "docker://registry.redhat.io/redhat/redhat-operator-index:v${ocp_version}" &>/dev/null; then
      logger.warn "Index not found for OCP ${ocp_version}; attempting fallback..."
      if attempt_fallback_for "$ocp_version" "${processed_versions[@]}"; then
        processed_versions+=("$ocp_version")
      else
        logger.error "Fallback failed for OCP ${ocp_version}; skipping."
      fi
      continue
    fi

    # --- try migration ---
    catalog_tmp_dir=$(mktemp -d)
    mkdir -p "${index_dir}/v${ocp_version}/catalog/serverless-operator"
    catalog_template="${index_dir}/v${ocp_version}/catalog-template.yaml"

    if ! opm migrate "registry.redhat.io/redhat/redhat-operator-index:v${ocp_version}" "${catalog_tmp_dir}" -oyaml; then
      logger.error "opm migrate failed for OCP ${ocp_version}; attempting fallback..."
      rm -rf "${catalog_tmp_dir}"
      if attempt_fallback_for "$ocp_version" "${processed_versions[@]}"; then
        processed_versions+=("$ocp_version")
      else
        logger.error "Fallback after migration failure failed for OCP ${ocp_version}; skipping."
      fi
      continue
    fi

    # --- successful migration path ---
    opm alpha convert-template basic "${catalog_tmp_dir}/serverless-operator/catalog.yaml" -oyaml \
      > "${catalog_template}"

    while IFS=$'\n' read -r channel; do
      add_channel "${catalog_template}" "$channel"
      add_channel "${catalog_template}" "$channel" "$(metadata.get 'olm.replaces')"
    done < <(metadata.get 'olm.channels.list[*]')

    level=none
    if versions.ge "$ocp_version" "4.17" ; then
      level="bundle-object-to-csv-metadata"
    fi

    opm alpha render-template basic --migrate-level="$level" "${catalog_template}" -oyaml \
      > "${index_dir}/v${ocp_version}/catalog/serverless-operator/catalog.yaml"

    sed -ri "s#(.*)(${SERVERLESS_BUNDLE})(.*)#\1${SERVERLESS_BUNDLE_REDHAT_IO}\3#" \
      "${index_dir}/v${ocp_version}/catalog/serverless-operator/catalog.yaml"

    rm -rf "${catalog_tmp_dir}"
    processed_versions+=("$ocp_version")
  done < <(metadata.get 'requirements.ocpVersion.list[*]')
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------
logger.info "Upgrading registry.redhat.io images"
upgrade_dependencies_images

logger.info "Generating catalog"
generate_catalog

logger.info "Generating ImageContentSourcePolicy"
default_serverless_operator_images
create_image_content_source_policy "${INDEX_IMAGE}" "$registry_redhat_io" "$registry_quay" "$registry_quay_previous" \
  "olm-catalog/serverless-operator-index/image_content_source_policy.yaml" ".tekton/images-mirror-set.yaml"
