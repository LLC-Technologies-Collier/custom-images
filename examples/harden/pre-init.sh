#!/bin/bash
#
# This script creates a hardened custom image.
# Derived from pre-init.sh
#

function version_ge(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|tail -n1)" ]]; }
function version_gt(){ [[ "$1" = "$2" ]]&& return 1 || version_ge "$1" "$2";}
function version_le(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|head -n1)" ]]; }
function version_lt(){ [[ "$1" = "$2" ]]&& return 1 || version_le "$1" "$2";}

set -e

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi

source examples/harden/lib/env.sh
source examples/harden/lib/util.sh


IMAGE_VERSION="$1"
if [[ -z "${IMAGE_VERSION}" ]] ; then
  IMAGE_VERSION="$(jq    -r .IMAGE_VERSION        env.json)" ; fi

export tmpdir="${REPRO_TMPDIR}/${IMAGE_VERSION}"
mkdir -p "${tmpdir}/sentinels"

region="$(echo "${ZONE}" | perl -pe 's/-[a-z]+$//')"

custom_image_zone="${ZONE}"
disk_size_gb="30" # greater than or equal to 30 (32 for rocky8)

# If no OS family specified, default to debian
if [[ "${IMAGE_VERSION}" != *-* ]] ; then
  case "${IMAGE_VERSION}" in
    "2.3" ) dataproc_version="${IMAGE_VERSION}-debian12" ;;
    "2.2" ) dataproc_version="${IMAGE_VERSION}-debian12" ;;
    "2.1" ) dataproc_version="${IMAGE_VERSION}-debian11" ;;
    "2.0" ) dataproc_version="${IMAGE_VERSION}-debian10" ;;
    "1.5" ) dataproc_version="${IMAGE_VERSION}-debian10" ;;
  esac
else
  dataproc_version="${IMAGE_VERSION}"
fi

case "${dataproc_version}" in
  "1.5-debian10"     ) short_dp_ver=1.5-deb10 ; disk_size_gb="20";;
  "2.0-debian10"     ) short_dp_ver=2.0-deb10 ;;
  "2.0-rocky8"       ) short_dp_ver=2.0-roc8 ; disk_size_gb="32";;
  "2.0-ubuntu18"     ) short_dp_ver=2.0-ubu18 ;;
  "2.1-debian11"     ) short_dp_ver=2.1-deb11 ;;
  "2.1-rocky8"       ) short_dp_ver=2.1-roc8 ;;
  "2.1-ubuntu20"     ) short_dp_ver=2.1-ubu20 ;;
  "2.1-ubuntu20-arm" ) short_dp_ver=2.1-ubu20-arm ;;
  "2.2-debian12"     ) short_dp_ver=2.2-deb12 ;;
  "2.2-rocky9"       ) short_dp_ver=2.2-roc9 ;;
  "2.2-ubuntu22"     ) short_dp_ver=2.2-ubu22 ;;
  "2.3-debian12"     ) short_dp_ver=2.3-deb12 ;;
  "2.3-rocky9"       ) short_dp_ver=2.3-roc9 ;;
  "2.3-ubuntu22"     ) short_dp_ver=2.3-ubu22 ;;
  "2.3-ml-ubuntu22"  ) short_dp_ver=2.3-ml-ubu22 ; disk_size_gb="50";;
esac

function create_h100_instance() {
  python3 generate_custom_image.py \
    --machine-type "a3-highgpu-2g" \
    --accelerator  "type=nvidia-h100-80gb,count=2" \
    $*
}

function create_t4_instance() {
  python3 generate_custom_image.py \
    --machine-type "n1-standard-32" \
    --accelerator  "type=nvidia-tesla-t4,count=1" \
    $*
}

function create_unaccelerated_instance() {
  python3 generate_custom_image.py \
    --machine-type "n1-standard-2" \
    $*
}

function create_highcpu_instance() {
  python3 generate_custom_image.py \
    --machine-type "n2-standard-32" \
    $*
}


function generate_from_dataproc_version() {
  generate --dataproc-version "$1"
}

function generate_from_base_purpose() {
  local img_pfx="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images"
  generate --base-image-uri "${img_pfx}/dataproc-${short_dp_ver/\./-}-${timestamp}-${1}"
}

function generate() {

  local extra_args="$*"
  local image_name="dataproc-${short_dp_ver//\./-}-${timestamp}-${PURPOSE}"

  print_status "Processing image ${image_name} for ${dataproc_version}"

  local images_json_file="${tmpdir}/images.json"
  if [[ ! -s "${images_json_file}" ]]; then
    print_status "Fetching current images list for ${PROJECT_ID}... "
    if gcloud compute images list --project="${PROJECT_ID}" --format json > "${images_json_file}"; then
      report_result "Done"
    else
      report_result "FAIL"
      exit 1
    fi
  fi

  local instances_json_file="${tmpdir}/instances.json"
  if [[ ! -s "${instances_json_file}" ]]; then
    print_status "Fetching current instances list for ${PROJECT_ID}... "
    if gcloud compute instances list --project="${PROJECT_ID}" --zones "${ZONE}" --format json > "${instances_json_file}"; then
      report_result "Done"
    else
      report_result "FAIL"
      exit 1
    fi
  fi

  local image="$(jq -r ".[] | select(.name == \"${image_name}\").name" "${images_json_file}" 2>/dev/null || echo '')"

  if [[ -n "${image}" ]] ; then
    print_status "Image ${image_name} already exists. "
    report_result "Skipped"
  else
    declare -a metadata_args
    metadata_args+=("invocation-type=custom-images")
    metadata_args+=("dataproc-temp-bucket=${TEMP_BUCKET}")

    local universe_domain
    universe_domain=$(gcloud config get core/universe_domain 2>/dev/null || echo "googleapis.com")
    metadata_args+=("universe-domain=${universe_domain}")

    # Pass MOK secrets for signing
    eval "$(bash examples/harden/create-key-pair.sh)"
    metadata_args+=(
      "public_secret_name=${public_secret_name}"
      "private_secret_name=${private_secret_name}"
      "secret_project=${secret_project}"
      "secret_version=${secret_version}"
      "modulus_md5sum=${modulus_md5sum}"
    )

    local metadata_string=$(IFS=,; echo "${metadata_args[*]}")

    print_status "Generating image ${image_name}..."
    
    local create_func="${CREATE_FUNCTION:-create_highcpu_instance}"
    print_status "Using instance creation function: ${create_func}"

    local optional_components_flag=""
    if [[ -n "${OPTIONAL_COMPONENTS:-}" ]]; then
      optional_components_flag="--optional-components=${OPTIONAL_COMPONENTS}"
      print_status "Installing optional components: ${OPTIONAL_COMPONENTS}"
    fi

    "${create_func}" \
      --project-id           "${PROJECT_ID}" \
      --image-name           "${image_name}" \
      --customization-script "${customization_script}" \
      --service-account      "${GSA}" \
      --metadata             "${metadata_string}" \
      --zone                 "${custom_image_zone}" \
      --disk-size            "${disk_size_gb}" \
      --gcs-bucket           "${BUCKET}" \
      --subnet               "${SUBNET}" \
      ${optional_components_flag} \
      --trusted-cert "tls/db.der" \
      --shutdown-instance-timer-sec=300 \
      --no-smoke-test \
      ${extra_args}
  fi
}


if [[ -f /custom-images/key.json ]]; then
  gcloud auth activate-service-account --key-file=/custom-images/key.json
fi

# ==========================================
# Layer 2 Purpose Registry
# Defines known bundles of scripts, instance footprints, and components.
# Paths are relative to DATAPROC_EVOLUTION_DIR.
# ==========================================
declare -A REGISTRY_SCRIPT
declare -A REGISTRY_FUNC
declare -A REGISTRY_COMPONENTS

# GPU Drivers (Bespoke install Action)
REGISTRY_SCRIPT[gpu]="initialization-actions/gpu/install_gpu_driver.sh"
REGISTRY_FUNC[gpu]="create_t4_instance"
REGISTRY_COMPONENTS[gpu]=""

# Docker (Optional Component via No-Op Script)
REGISTRY_SCRIPT[docker]="custom-images/examples/harden/no-customization.sh"
REGISTRY_FUNC[docker]="create_highcpu_instance"
REGISTRY_COMPONENTS[docker]="DOCKER"

# Jupyter (Optional Component via No-Op Script)
REGISTRY_SCRIPT[jupyter]="custom-images/examples/harden/no-customization.sh"
REGISTRY_FUNC[jupyter]="create_highcpu_instance"
REGISTRY_COMPONENTS[jupyter]="JUPYTER"

# Secure Proxy
REGISTRY_SCRIPT[secure-proxy]="custom-images/startup_script/gce-proxy-setup.sh"
REGISTRY_FUNC[secure-proxy]="create_highcpu_instance"
REGISTRY_COMPONENTS[secure-proxy]=""

# Zeppelin (Optional Component via No-Op Script)
REGISTRY_SCRIPT[zeppelin]="custom-images/examples/harden/no-customization.sh"
REGISTRY_FUNC[zeppelin]="create_highcpu_instance"
REGISTRY_COMPONENTS[zeppelin]="ZEPPELIN"

# Pig (Optional Component via No-Op Script)
REGISTRY_SCRIPT[pig]="custom-images/examples/harden/no-customization.sh"
REGISTRY_FUNC[pig]="create_highcpu_instance"
REGISTRY_COMPONENTS[pig]="PIG"

# Delta Lake (Optional Component via No-Op Script)
REGISTRY_SCRIPT[delta]="custom-images/examples/harden/no-customization.sh"
REGISTRY_FUNC[delta]="create_highcpu_instance"
REGISTRY_COMPONENTS[delta]="DELTA"




# Default Layer 2 purposes if none specified in env.json
LAYER2_PURPOSES=("gpu")

# Attempt to read LAYER2_PURPOSES from env.json
if [[ -f env.json ]]; then
  if jq -e '.LAYER2_PURPOSES' env.json >/dev/null 2>&1; then
    mapfile -t LAYER2_PURPOSES < <(jq -r '.LAYER2_PURPOSES[]' env.json)
    print_status "Loaded Layer 2 purposes from env.json: ${LAYER2_PURPOSES[*]}"
  fi
fi

# Validation: Fail Fast on unknown purposes before initiating builds
for purpose_key in "${LAYER2_PURPOSES[@]}"; do
  [[ -z "${purpose_key}" ]] && continue
  if [[ -z "${REGISTRY_SCRIPT[$purpose_key]+_}" ]]; then
    print_status "CRITICAL ERROR: Unknown purpose key in config: '${purpose_key}'"
    print_status "Aborting build. Please check your registry definitions."
    exit 1
  fi
done

# ==========================================
# LAYER 1: Hardened Kernel
# ==========================================

PURPOSE="hardened-kernel"
customization_script="examples/harden/harden-kernel-and-os.sh"
CREATE_FUNCTION="create_highcpu_instance"
OPTIONAL_COMPONENTS=""
print_status "=== Generating hardened kernel image (Layer 1) for ${dataproc_version} ==="
generate_from_dataproc_version "${dataproc_version}"

LAST_PURPOSE="hardened-kernel"

# ==========================================
# LAYER 2: Customizations (Sandwich Layers)
# ==========================================
for purpose_key in "${LAYER2_PURPOSES[@]}"; do
  # Handle empty lines
  [[ -z "${purpose_key}" ]] && continue

  PURPOSE="${purpose_key}"
  customization_script="${DATAPROC_EVOLUTION_DIR}/${REGISTRY_SCRIPT[$purpose_key]}"
  CREATE_FUNCTION="${REGISTRY_FUNC[$purpose_key]}"
  OPTIONAL_COMPONENTS="${REGISTRY_COMPONENTS[$purpose_key]}"

  
  print_status "=== Generating ${PURPOSE} image (Layer 2) for ${dataproc_version} ==="
  print_status "    Script: ${REGISTRY_SCRIPT[$purpose_key]}"
  print_status "    Footprint: ${CREATE_FUNCTION}"
  print_status "    Components: ${OPTIONAL_COMPONENTS:-None}"

  generate_from_base_purpose "${LAST_PURPOSE}"
  
  LAST_PURPOSE="${PURPOSE}"
done


# ==========================================
# LAYER 3: Hardened Userspace Confinement
# ==========================================
PURPOSE="hardened-userspace"
customization_script="examples/harden/harden-userspace.sh"
CREATE_FUNCTION="create_highcpu_instance"
OPTIONAL_COMPONENTS=""
print_status "=== Generating hardened userspace image (Layer 3) for ${dataproc_version} ==="
generate_from_base_purpose "${LAST_PURPOSE}"



