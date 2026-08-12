#!/bin/bash
#
# harden-kernel-and-os.sh
#
# This script is intended to be run as a customization script during a
# Dataproc custom image build. It performs the following actions:
#   1. Installs kernel build dependencies.
#   2. Clones Stephen Smalley's custom kernel branch (SELinux Namespaces).
#   3. Bases the kernel configuration on the running GCE instance's config.
#   4. Applies additional hardening flags and enables SELinux Namespaces.
#   5. Compiles the kernel and signed modules.
#   6. Installs the new kernel and updates the bootloader.

set -euo pipefail

# --- Configuration ---
KERNEL_FORK_URL="https://github.com/stephensmalley/selinux-kernel"
KERNEL_BRANCH="working-selinuxns"
BUILD_DIR="/usr/local/src/kernel-build"
CA_TMPDIR="/dev/shm/signing-keys"

# ANSI Colors for logging
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

function print_status() {
    echo -e "${BLUE}[STATUS] ${1}${NC}" >&2
}

function print_success() {
    echo -e "${GREEN}[SUCCESS] ${1}${NC}" >&2
}

function print_warning() {
    echo -e "${YELLOW}[WARNING] ${1}${NC}" >&2
}

function print_error() {
    echo -e "${RED}[ERROR] ${1}${NC}" >&2
}

# --- Metadata Helper ---
function get_metadata_attribute() {
  local -r attribute_name="$1"
  local -r default_value="${2:-}"
  local -r MDS_PREFIX="http://metadata.google.internal/computeMetadata/v1"
  
  set +e
  local value
  value=$(curl -s -f -H "Metadata-Flavor: Google" \
    --connect-timeout 2 --max-time 5 \
    "${MDS_PREFIX}/instance/attributes/${attribute_name}" 2>/dev/null)
  local return_code=$?
  set -e

  if [[ ${return_code} == 0 ]]; then
    echo -n "${value}"
  else
    echo -n "${default_value}"
  fi
}

# --- 1. Install Dependencies ---
function install_dependencies() {
    print_status "Installing kernel build dependencies..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -qq
        apt-get install -y -qq \
            git build-essential libncurses-dev bison flex libssl-dev libelf-dev \
            libdw-dev rsync \
            bc dwarves openssl lz4 sbsigntool
    elif command -v dnf >/dev/null 2>&1; then
        dnf groupinstall -y "Development Tools"
        dnf install -y \
            git ncurses-devel bison flex openssl-devel elfutils-libelf-devel \
            bc dwarves openssl lz4 sbsigntools
    elif command -v yum >/dev/null 2>&1; then
        yum groupinstall -y "Development Tools"
        yum install -y \
            git ncurses-devel bison flex openssl-devel elfutils-libelf-devel \
            bc dwarves openssl lz4 sbsigntools
    else
        print_error "Unsupported package manager. Cannot install dependencies."
        exit 1
    fi
    print_success "Dependencies installed."
}


# --- Cache Helpers ---
function get_cache_bucket() {
    local bucket
    bucket=$(get_metadata_attribute "dataproc-bucket" "")
    if [[ -z "${bucket}" ]]; then
        bucket=$(get_metadata_attribute "dataproc-temp-bucket" "")
    fi
    echo -n "${bucket}"
}

function get_kernel_commit() {
    local commit
    commit=$(git ls-remote "${KERNEL_FORK_URL}" "refs/heads/${KERNEL_BRANCH}" | awk '{print $1}')
    echo -n "${commit}"
}

function check_cache() {
    local bucket
    bucket=$(get_cache_bucket)
    if [[ -z "${bucket}" ]]; then
        print_warning "Cache bucket not configured. Skipping cache check."
        return 1
    fi

    local commit
    commit=$(get_kernel_commit)
    if [[ -z "${commit}" ]]; then
        print_warning "Could not determine remote kernel commit. Skipping cache check."
        return 1
    fi

    local image_version
    image_version=$(get_metadata_attribute "dataproc_dataproc_version" "unknown")

    local arch
    arch=$(uname -m)

    local cache_path="gs://${bucket}/kernel-cache/${image_version}/${arch}/${KERNEL_BRANCH}/${commit}"
    print_status "Checking cache at ${cache_path}..."

    mkdir -p "${BUILD_DIR}"
    
    if command -v dpkg >/dev/null 2>&1; then
        if gsutil ls "${cache_path}/*.deb" >/dev/null 2>&1; then
            print_success "Cache HIT. Downloading packages..."
            gsutil -m cp "${cache_path}/*.deb" "${BUILD_DIR}/"
            return 0
        fi
    elif command -v rpm >/dev/null 2>&1; then
        if gsutil ls "${cache_path}/*.rpm" >/dev/null 2>&1; then
            print_success "Cache HIT. Downloading packages..."
            gsutil -m cp "${cache_path}/*.rpm" "${BUILD_DIR}/"
            return 0
        fi
    fi

    print_status "Cache MISS."
    return 1
}

function save_cache() {
    local bucket
    bucket=$(get_cache_bucket)
    if [[ -z "${bucket}" ]]; then
        return 0
    fi

    local commit
    commit=$(get_kernel_commit)
    if [[ -z "${commit}" ]]; then
        return 0
    fi

    local image_version
    image_version=$(get_metadata_attribute "dataproc_dataproc_version" "unknown")

    local arch
    arch=$(uname -m)

    local cache_path="gs://${bucket}/kernel-cache/${image_version}/${arch}/${KERNEL_BRANCH}/${commit}"
    print_status "Saving packages to cache at ${cache_path}..."

    pushd "${BUILD_DIR}"
    if command -v dpkg >/dev/null 2>&1; then
        if ls *.deb >/dev/null 2>&1; then
            gsutil -m cp *.deb "${cache_path}/"
        fi
    elif command -v rpm >/dev/null 2>&1; then
        if ls *.rpm >/dev/null 2>&1; then
            gsutil -m cp *.rpm "${cache_path}/"
        fi
    fi
    popd
    print_success "Cache saved."
}


# --- 2. Clone Kernel Source ---
function clone_source() {
    # This function is skipped if cache hit
    print_status "Fetching kernel source archive from ${KERNEL_FORK_URL} (Branch: ${KERNEL_BRANCH})..."
    mkdir -p "${BUILD_DIR}"
    
    if [[ ! -f "${BUILD_DIR}/linux/Makefile" ]]; then
        local bucket
        bucket=$(get_cache_bucket)
        local commit
        commit=$(get_kernel_commit)
        local tarball_cached=0

        if [[ -n "${bucket}" && -n "${commit}" ]]; then
            local tarball_cache_path="gs://${bucket}/kernel-source-cache/${KERNEL_BRANCH}/${commit}/selinux-kernel.tar.gz"
            print_status "Checking source cache at ${tarball_cache_path}..."
            if gsutil ls "${tarball_cache_path}" >/dev/null 2>&1; then
                print_success "Source cache HIT. Downloading archive..."
                gsutil cp "${tarball_cache_path}" "${BUILD_DIR}/selinux-kernel.tar.gz"
                tarball_cached=1
            fi
        fi

        if [[ "${tarball_cached}" -eq 0 ]]; then
            local archive_url="${KERNEL_FORK_URL}/archive/refs/heads/${KERNEL_BRANCH}.tar.gz"
            print_status "Downloading archive from GitHub: ${archive_url}"
            
            # Use curl to download with resume support
            if ! curl -L "${archive_url}" -o "${BUILD_DIR}/selinux-kernel.tar.gz"; then
                print_error "Failed to download kernel archive."
                exit 1
            fi

            if [[ -n "${bucket}" && -n "${commit}" ]]; then
                local tarball_cache_path="gs://${bucket}/kernel-source-cache/${KERNEL_BRANCH}/${commit}/selinux-kernel.tar.gz"
                print_status "Saving source to cache at ${tarball_cache_path}..."
                gsutil cp "${BUILD_DIR}/selinux-kernel.tar.gz" "${tarball_cache_path}"
                print_success "Source cache saved."
            fi
        fi
        
        print_status "Unpacking archive..."
        mkdir -p "${BUILD_DIR}/linux"
        if ! tar -xzf "${BUILD_DIR}/selinux-kernel.tar.gz" -C "${BUILD_DIR}/linux" --strip-components=1; then
            print_error "Failed to unpack kernel archive."
            rm -f "${BUILD_DIR}/selinux-kernel.tar.gz"
            exit 1
        fi
        
        # Cleanup archive to save space
        rm -f "${BUILD_DIR}/selinux-kernel.tar.gz"
    else
        print_status "Source already unpacked in ${BUILD_DIR}/linux. Skipping download."
    fi
    print_success "Source ready in ${BUILD_DIR}/linux"
}


# --- 3. Configure Kernel ---
function configure_kernel() {
    print_status "Configuring kernel..."
    pushd "${BUILD_DIR}/linux"

    local running_config="/boot/config-$(uname -r)"
    if [[ ! -f "${running_config}" ]]; then
        print_error "Could not find running config at ${running_config}"
        exit 1
    fi

    print_status "Copying baseline config from ${running_config}..."
    cp "${running_config}" .config

    # Apply defaults for any new options in this fork
    make olddefconfig

    print_status "Applying hardening and feature flags..."
    
    # Enable Requested Feature
    scripts/config --enable SECURITY_SELINUX_NS

    # --- Hardening Flags ---
    # 1. Integer/Buffer Integrity
    scripts/config --enable INIT_STACK_ALL_ZERO
    scripts/config --enable SLAB_FREELIST_HARDENED
    scripts/config --enable FORTIFY_SOURCE

    # 2. Attack Surface Reduction
    scripts/config --disable DEVMEM
    scripts/config --enable IMA

    print_status "Running olddefconfig again to validate changes..."
    make olddefconfig

    popd
    print_success "Kernel configured."
}

# --- 4. Retrieve Keys for Signing ---
function retrieve_keys() {
    print_status "Retrieving signing keys from Secret Manager..."
    
    local sig_priv_secret_name
    sig_priv_secret_name=$(get_metadata_attribute "private_secret_name")
    local sig_pub_secret_name
    sig_pub_secret_name=$(get_metadata_attribute "public_secret_name")
    local sig_secret_project
    sig_secret_project=$(get_metadata_attribute "secret_project")
    local sig_secret_version
    sig_secret_version=$(get_metadata_attribute "secret_version" "1")

    if [[ -z "${sig_priv_secret_name}" || -z "${sig_pub_secret_name}" || -z "${sig_secret_project}" ]]; then
        print_warning "Signing metadata missing. Skipping retrieval. Kernel will NOT be signed."
        return 0
    fi

    mkdir -p "${CA_TMPDIR}"

    # Write private material
    gcloud secrets versions access "${sig_secret_version}" \
        --project="${sig_secret_project}" \
        --secret="${sig_priv_secret_name}" \
        | dd status=none of="${CA_TMPDIR}/db.rsa"

    # Write public material (Certificate)
    gcloud secrets versions access "${sig_secret_version}" \
        --project="${sig_secret_project}" \
        --secret="${sig_pub_secret_name}" \
        | base64 --decode \
        | dd status=none of="${CA_TMPDIR}/db.der"

    # Convert DER to PEM for some tools if needed
    openssl x509 -inform DER -in "${CA_TMPDIR}/db.der" -outform PEM -out "${CA_TMPDIR}/db.pem"

    print_success "Signing keys retrieved."
}

# --- 5. Build Kernel ---
function build_kernel() {
    print_status "Building kernel (this may take some time)..."
    pushd "${BUILD_DIR}/linux"

    # Use all available cores
    local num_cores
    num_cores=$(nproc)
    
    if command -v dpkg >/dev/null 2>&1; then
        print_status "Debian detected. Building with bindeb-pkg..."
        make -j"${num_cores}" bindeb-pkg
    elif command -v rpmbuild >/dev/null 2>&1; then
        print_status "RedHat/Rocky detected. Building with binrpm-pkg..."
        make -j"${num_cores}" binrpm-pkg
    else
        print_error "Unsupported package manager. Cannot build kernel packages."
        exit 1
    fi


    popd
    print_success "Kernel packages built."
}

# --- 6. Sign Kernel Modules and Image ---
function sign_artifacts() {
    print_status "Signing artifacts..."
    
    if [[ ! -f "${CA_TMPDIR}/db.rsa" ]]; then
        print_warning "No signing keys found. Skipping signing."
        return 0
    fi

    # Assuming bindeb-pkg/binrpm-pkg generates packages in the parent directory
    pushd "${BUILD_DIR}"
    
    # We need to install the kernel first to sign its installed modules, 
    # or unpack the package, sign, and repack.
    # For simplicity in this customization script (which runs on the target disk),
    # we install the packages, then sign the resulting modules in /lib/modules.
    
    print_status "Installing custom kernel packages..."
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -i linux-image-*.deb linux-headers-*.deb linux-libc-dev*.deb || true # Allow failure if already installed or partial
    elif command -v rpm >/dev/null 2>&1; then
        rpm -ivh kernel-*.rpm || true
    fi

    
    local new_uname
    new_uname=$(ls /boot/vmlinuz-* | grep -v "$(uname -r)" | awk -F'vmlinuz-' '{print $2}' | sort -V | tail -n1)

    if [[ -z "${new_uname}" ]]; then
        print_error "Could not determine new kernel version."
        exit 1
    fi

    print_status "Signing kernel image: /boot/vmlinuz-${new_uname}"
    # sbsign requires PEM format for both key and certificate
    sbsign --key "${CA_TMPDIR}/db.rsa" --cert "${CA_TMPDIR}/db.pem" --output "/boot/vmlinuz-${new_uname}.signed" "/boot/vmlinuz-${new_uname}"
    mv "/boot/vmlinuz-${new_uname}.signed" "/boot/vmlinuz-${new_uname}"

    print_status "Signing kernel modules in /lib/modules/${new_uname}"
    # sign-file in the kernel tree typically expects PEM or DER depending on version, 
    # but existing scripts in this repo use DER (.der) for sign-file.
    for module in $(find "/lib/modules/${new_uname}/" -name '*.ko'); do
        "/lib/modules/${new_uname}/build/scripts/sign-file" sha256 \
        "${CA_TMPDIR}/db.rsa" \
        "${CA_TMPDIR}/db.der" \
        "${module}"
    done


    popd
    print_success "Artifacts signed and installed."
}

# --- 7. Update Bootloader ---
function update_bootloader() {
    print_status "Configuring bootloader parameters..."
    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "selinux=1" /etc/default/grub; then
            print_status "Adding SELinux parameters to /etc/default/grub"
            # We enable SELinux, set it to permissive (enforcing=0), and explicitly choose it over AppArmor
            sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 selinux=1 enforcing=0 security=selinux"/' /etc/default/grub
        else
            print_status "SELinux parameters already present in /etc/default/grub"
        fi
    fi

    print_status "Updating bootloader..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        if [[ -f /boot/efi/EFI/rocky/grub.cfg ]]; then
            grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg
        elif [[ -f /boot/efi/EFI/redhat/grub.cfg ]]; then
            grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        else
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
    else
        print_warning "No recognized bootloader update command found. Manual update might be needed."
    fi
    print_success "Bootloader updated."
}


# --- Cleanup ---
function cleanup() {
    print_status "Cleaning up..."
    rm -rf "${CA_TMPDIR}"
    print_success "Cleanup complete."
}

# --- Main Execution ---
function main() {
    # Ensure run as root
    if [[ $EUID -ne 0 ]]; then
       print_error "This script must be run as root (or via sudo)."
       exit 1
    fi

    install_dependencies
    
    if check_cache; then
        print_status "Skipping kernel build, using packages from cache."
    else
        clone_source
        configure_kernel
        build_kernel
        save_cache
    fi

    retrieve_keys
    sign_artifacts
    update_bootloader
    cleanup

    print_success "Hardened Kernel and OS setup complete!"
    echo "BuildSucceeded: Customization script complete."
}

main "$@"
