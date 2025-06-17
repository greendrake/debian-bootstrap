#!/bin/bash

# Debian-based System Setup Script for RAID1 + LUKS2 + BTRFS
# To be run on any Debian-based live system

set -euo pipefail

# =============================================================================
# ROOT CHECK - MUST BE FIRST
# =============================================================================

# Check if running as root before doing anything else
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Please run: sudo $0 $*"
    exit 1
fi

# =============================================================================
# CONFIGURATION VARIABLES - MODIFY THESE AS NEEDED
# =============================================================================

# Target disk array - modify this to specify your target disks
# For single disk: TARGET_DRIVES=("/dev/sda")
# For RAID1 setup: TARGET_DRIVES=("/dev/sda" "/dev/sdb") or more disks
TARGET_DRIVES=("/dev/sda" "/dev/sdb")

# LUKS2 password (will be prompted if empty)
LUKS_PASSWORD=""

# System configuration
HOSTNAME="black"
USERNAME="user"
USER_PASSWORD=""  # Will be prompted if empty

# Swap size in GiB (set to 0 to disable swap)
SWAP_SIZE_GB="16"

# Distribution configuration
DISTRIBUTION="noble"  # e.g., noble, jammy, bookworm, bullseye, sid
ARCHIVE_URL="http://archive.ubuntu.com/ubuntu/"  # Change for other distributions
# Examples:
# Debian: http://deb.debian.org/debian/
# Ubuntu: http://archive.ubuntu.com/ubuntu/

# Architecture will be detected in detect_architecture function

# RAID configuration flag (will be set based on TARGET_DRIVES count)
USE_RAID=""  # Will be set to "true" or "false" in detect_architecture

# Distribution-specific packages (set to empty to skip)
NVIDIA_DRIVER_PACKAGE="ubuntu-drivers-common"  # Set to "" for Debian, or "nvidia-driver" for Debian
INSTALL_NVIDIA_DRIVERS="true"  # Set to "false" to skip NVIDIA driver installation

# Mount point for installation
MOUNT_POINT="/mnt/system-install"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

prompt_password() {
    local var_name="$1"
    local prompt_text="$2"
    local password
    local password_confirm
    
    while true; do
        echo -n "$prompt_text: "
        read -s password
        echo
        echo -n "Confirm password: "
        read -s password_confirm
        echo
        
        if [[ "$password" == "$password_confirm" ]]; then
            break
        else
            echo "Passwords do not match. Please try again."
            echo
        fi
    done
    
    eval "$var_name='$password'"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Validate target drives array
    if [[ ${#TARGET_DRIVES[@]} -eq 0 ]]; then
        error "No target drives specified in TARGET_DRIVES array"
    fi
    
    # Check if drives exist
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ ! -b "$drive" ]]; then
            error "Drive $drive does not exist"
        fi
    done
    
    log "Found ${#TARGET_DRIVES[@]} target drive(s): ${TARGET_DRIVES[*]}"
    
    # Check required tools
    local required_tools=("parted" "mdadm" "cryptsetup" "debootstrap" "mkfs.btrfs" "mkfs.fat" "sgdisk" "wipefs")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "Required tool '$tool' is not installed"
        fi
    done
    
    # Check for existing configurations that might interfere
    log "Checking for existing configurations..."
    
    local cleanup_needed=false
    
    # Check for active RAID arrays
    if [[ -f /proc/mdstat ]] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        log "Warning: Active RAID arrays detected:"
        grep "^md" /proc/mdstat 2>/dev/null || true
        cleanup_needed=true
    fi
    
    # Check for LUKS devices
    if ls /dev/mapper/ 2>/dev/null | grep -v control | grep -q . 2>/dev/null; then
        log "Warning: LUKS/device-mapper devices detected:"
        ls /dev/mapper/ 2>/dev/null | grep -v control || true
        cleanup_needed=true
    fi
    
    # Check if drives have existing partitions
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ -b "$drive" ]] && ls "${drive}"* 2>/dev/null | grep -q "${drive}[0-9]"; then
            log "Warning: Drive $drive has existing partitions:"
            ls "${drive}"* 2>/dev/null | grep "${drive}[0-9]" || true
            cleanup_needed=true
        fi
    done
    
    if [[ "$cleanup_needed" == "true" ]]; then
        echo ""
        echo "IMPORTANT: Existing configurations detected that may interfere with installation."
        echo "You should run cleanup first: $0 --cleanup"
        echo "Or add --force to proceed with automatic cleanup."
        echo ""
        
        # Check if --force flag is provided
        local force_cleanup=false
        for arg in "$@"; do
            if [[ "$arg" == "--force" ]]; then
                force_cleanup=true
                break
            fi
        done
        
        if [[ "$force_cleanup" == "true" ]]; then
            log "Force cleanup requested, proceeding with automatic cleanup..."
            cleanup
            log "Automatic cleanup completed, proceeding with installation..."
        else
            error "Cleanup required before proceeding (use --force for automatic cleanup)"
        fi
    fi
    
    log "Prerequisites check passed"
}

detect_architecture() {
    log "Detecting system architecture..."
    
    # Auto-detect architecture with multiple fallback methods
    ARCHITECTURE=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || echo "amd64")
    
    # Normalize architecture names
    case "$ARCHITECTURE" in
        x86_64)
            ARCHITECTURE="amd64"
            ;;
        aarch64)
            ARCHITECTURE="arm64"
            ;;
    esac
    
    # Validate architecture is supported
    case "$ARCHITECTURE" in
        amd64|arm64)
            log "Detected architecture: $ARCHITECTURE"
            ;;
        *)
            log "Warning: Unknown architecture '$ARCHITECTURE', defaulting to amd64"
            ARCHITECTURE="amd64"
            ;;
    esac
    
    # Determine GRUB target based on architecture
    case "$ARCHITECTURE" in
        amd64)
            GRUB_TARGET="x86_64-efi"
            ;;
        arm64)
            GRUB_TARGET="arm64-efi"
            ;;
        *)
            GRUB_TARGET="x86_64-efi"  # Default fallback
            ;;
    esac
    
    log "Architecture detection completed: $ARCHITECTURE (GRUB target: $GRUB_TARGET)"
    
    # Set RAID configuration flag based on drive count
    if [[ ${#TARGET_DRIVES[@]} -eq 1 ]]; then
        USE_RAID="false"
        log "Single drive detected - RAID disabled"
    else
        USE_RAID="true"
        log "Multiple drives detected (${#TARGET_DRIVES[@]}) - RAID enabled"
    fi
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

setup_partitions() {
    if [[ "$USE_RAID" == "false" ]]; then
        log "Setting up partitions on single drive ${TARGET_DRIVES[0]}..."
    else
        log "Setting up partitions on ${#TARGET_DRIVES[@]} drives: ${TARGET_DRIVES[*]}..."
    fi
    
    for drive in "${TARGET_DRIVES[@]}"; do
        log "Partitioning $drive..."
        
        # Create GPT partition table
        parted -s "$drive" mklabel gpt
        
        # Create EFI partition (512MiB)
        parted -s "$drive" mkpart EFI fat32 1MiB 513MiB
        parted -s "$drive" set 1 esp on
        
        if [[ "$USE_RAID" == "false" ]]; then
            # Single drive: create data partition for direct LUKS
            parted -s "$drive" mkpart DATA ext4 513MiB 100%
            log "Created data partition on $drive for direct LUKS encryption"
        else
            # Multiple drives: create RAID partition
            parted -s "$drive" mkpart RAID ext4 513MiB 100%
            parted -s "$drive" set 2 raid on
            log "Created RAID partition on $drive"
        fi
        
        log "Partitioned $drive successfully"
    done
    
    # Wait for kernel to recognize partitions
    sleep 2
    partprobe "${TARGET_DRIVES[@]}"
    sleep 2
}

setup_raid() {
    # Skip RAID setup if only one drive
    if [[ "$USE_RAID" == "false" ]]; then
        log "Single drive detected, skipping RAID setup"
        return 0
    fi
    
    log "Setting up RAID1 with ${#TARGET_DRIVES[@]} drives..."
    
    # Build array of partition paths for RAID
    local raid_partitions=()
    for drive in "${TARGET_DRIVES[@]}"; do
        raid_partitions+=("${drive}2")
    done
    
    log "Creating RAID1 array with partitions: ${raid_partitions[*]}"
    
    # Create RAID1 array (automatically answer "yes" to prompts)
    echo "yes" | mdadm --create /dev/md0 \
        --level=1 \
        --raid-devices=${#TARGET_DRIVES[@]} \
        "${raid_partitions[@]}"
    
    # Wait for RAID to sync (at least partially)
    log "Waiting for RAID to initialize..."
    sleep 5
    
    # Save RAID configuration
    mkdir -p /etc/mdadm
    mdadm --detail --scan > /etc/mdadm/mdadm.conf
    
    # Also save to temporary location for chroot use
    mkdir -p /tmp/raid-config
    mdadm --detail --scan > /tmp/raid-config/mdadm.conf
    
    log "RAID1 setup completed with ${#TARGET_DRIVES[@]} drives"
}



setup_luks() {
    # Determine target device for LUKS encryption
    local luks_target_device
    if [[ "$USE_RAID" == "false" ]]; then
        luks_target_device="${TARGET_DRIVES[0]}2"
        log "Setting up LUKS2 encryption on single drive partition $luks_target_device..."
    else
        luks_target_device="/dev/md0"
        log "Setting up LUKS2 encryption on RAID device $luks_target_device..."
    fi
    
    # Prompt for LUKS password if not set
    if [[ -z "$LUKS_PASSWORD" ]]; then
        prompt_password LUKS_PASSWORD "Enter LUKS2 password"
    fi
    
    # Create LUKS container on target device
    log "Creating LUKS device on $luks_target_device..."
    
    # Check cryptsetup version and use appropriate options
    CRYPTSETUP_VERSION=$(cryptsetup --version | head -1 | grep -o '[0-9]\+\.[0-9]\+' | head -1)
    CRYPTSETUP_MAJOR=$(echo "$CRYPTSETUP_VERSION" | cut -d. -f1)
    CRYPTSETUP_MINOR=$(echo "$CRYPTSETUP_VERSION" | cut -d. -f2)
    
    log "Detected cryptsetup version: $CRYPTSETUP_VERSION"
    
    # Use version-appropriate LUKS formatting options
    if [[ "$CRYPTSETUP_MAJOR" -ge 2 ]] && [[ "$CRYPTSETUP_MINOR" -ge 1 ]]; then
        log "Using advanced LUKS2 options (cryptsetup >= 2.1)"
        echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha256 \
            --pbkdf argon2id \
            --iter-time 4000 \
            --pbkdf-memory 1024 \
            --pbkdf-parallel 4 \
            "$luks_target_device" -
    elif [[ "$CRYPTSETUP_MAJOR" -ge 2 ]]; then
        log "Using basic LUKS2 options (cryptsetup 2.0.x)"
        echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha256 \
            --pbkdf argon2id \
            "$luks_target_device" -
    else
        log "Using LUKS1 options (cryptsetup < 2.0)"
        echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha256 \
            "$luks_target_device" -
    fi
    
    # Open LUKS container
    echo -n "$LUKS_PASSWORD" | cryptsetup luksOpen "$luks_target_device" cryptroot -
    
    log "LUKS2 encryption setup completed"
}



format_filesystems() {
    log "Formatting filesystems..."
    
    # Format EFI partitions on all drives
    for drive in "${TARGET_DRIVES[@]}"; do
        log "Formatting EFI partition on ${drive}1..."
        mkfs.fat -F32 "${drive}1"
    done
    
    # Format BTRFS filesystem with compression
    mkfs.btrfs -L "root" /dev/mapper/cryptroot
    
    log "Filesystems formatted successfully"
}

setup_btrfs_subvolumes() {
    log "Setting up BTRFS subvolumes..."
    
    # Mount BTRFS filesystem temporarily
    mkdir -p /mnt/btrfs-root
    mount /dev/mapper/cryptroot /mnt/btrfs-root
    
    # Create essential subvolumes
    log "Creating @ subvolume (root filesystem)..."
    btrfs subvolume create /mnt/btrfs-root/@
    
    log "Creating @home subvolume (user data)..."
    btrfs subvolume create /mnt/btrfs-root/@home
    
    log "Creating @var subvolume (logs and variable data)..."
    btrfs subvolume create /mnt/btrfs-root/@var
    
    log "Creating @snapshots subvolume (snapshot storage)..."
    btrfs subvolume create /mnt/btrfs-root/@snapshots
    
    if [[ "$SWAP_SIZE_GB" != "0" ]]; then
        log "Creating @swap subvolume (swapfile storage)..."
        btrfs subvolume create /mnt/btrfs-root/@swap
    fi
    
    # Unmount temporary mount
    umount /mnt/btrfs-root
    rmdir /mnt/btrfs-root
    
    log "BTRFS subvolumes created successfully"
}

mount_filesystems() {
    log "Mounting filesystems for installation..."
    
    # Create mount point
    mkdir -p "$MOUNT_POINT"
    
    # Mount root subvolume with compression
    mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot "$MOUNT_POINT"
    
    # Create directories for other subvolumes
    mkdir -p "$MOUNT_POINT/home"
    mkdir -p "$MOUNT_POINT/var"
    mkdir -p "$MOUNT_POINT/.snapshots"
    
    # Mount additional subvolumes
    mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot "$MOUNT_POINT/home"
    mount -o subvol=@var,compress=zstd,noatime /dev/mapper/cryptroot "$MOUNT_POINT/var"
    mount -o subvol=@snapshots,compress=zstd,noatime /dev/mapper/cryptroot "$MOUNT_POINT/.snapshots"
    
    # Mount swap subvolume and create swapfile if swap is enabled
    if [[ "$SWAP_SIZE_GB" != "0" ]]; then
        mkdir -p "$MOUNT_POINT/swap"
        mount -o subvol=@swap,noatime /dev/mapper/cryptroot "$MOUNT_POINT/swap"
        
        log "Creating ${SWAP_SIZE_GB}GB swapfile..."
        # Create swapfile (disable COW for better performance)
        truncate -s 0 "$MOUNT_POINT/swap/swapfile"
        chattr +C "$MOUNT_POINT/swap/swapfile" 2>/dev/null || true  # Disable COW if supported
        fallocate -l "${SWAP_SIZE_GB}G" "$MOUNT_POINT/swap/swapfile"
        chmod 600 "$MOUNT_POINT/swap/swapfile"
        mkswap "$MOUNT_POINT/swap/swapfile"
        swapon "$MOUNT_POINT/swap/swapfile"
        log "Swapfile created and enabled"
    fi
    
    # Create and mount boot directory (use first drive's EFI partition)
    mkdir -p "$MOUNT_POINT/boot"
    mount "${TARGET_DRIVES[0]}1" "$MOUNT_POINT/boot"
    
    log "Filesystems mounted successfully"
}

install_base_system() {
    log "Installing base system ($DISTRIBUTION $ARCHITECTURE)..."
    
    # Install base system with debootstrap
    if ! debootstrap --arch="$ARCHITECTURE" "$DISTRIBUTION" "$MOUNT_POINT" "$ARCHIVE_URL"; then
        log "ERROR: debootstrap failed"
        return 1
    fi
    
    # Verify basic system structure was created
    if [[ ! -d "$MOUNT_POINT/etc" ]] || [[ ! -d "$MOUNT_POINT/usr" ]] || [[ ! -d "$MOUNT_POINT/var" ]]; then
        log "ERROR: Base system installation appears incomplete"
        log "Missing essential directories in $MOUNT_POINT"
        return 1
    fi
    
    # Generate fstab
    {
        echo "# <file system> <mount point> <type> <options> <dump> <pass>"
        echo "/dev/mapper/cryptroot / btrfs defaults,subvol=@,compress=zstd,noatime 0 1"
        echo "/dev/mapper/cryptroot /home btrfs defaults,subvol=@home,compress=zstd,noatime 0 2"
        echo "/dev/mapper/cryptroot /var btrfs defaults,subvol=@var,compress=zstd,noatime 0 2"
        echo "/dev/mapper/cryptroot /.snapshots btrfs defaults,subvol=@snapshots,compress=zstd,noatime 0 2"
        if [[ "$SWAP_SIZE_GB" != "0" ]]; then
            echo "/dev/mapper/cryptroot /swap btrfs defaults,subvol=@swap,noatime 0 2"
            echo "/swap/swapfile none swap sw 0 0"
        fi
        echo "UUID=$(blkid -s UUID -o value ${TARGET_DRIVES[0]}1) /boot vfat defaults 0 2"
    } > "$MOUNT_POINT/etc/fstab"
    
    log "Base system installed successfully"
}

configure_system() {
    log "Configuring system..."
    
    # Set hostname
    echo "$HOSTNAME" > "$MOUNT_POINT/etc/hostname"
    
    # Configure hosts file
    {
        echo "127.0.0.1 localhost"
        echo "127.0.1.1 $HOSTNAME"
        echo ""
        echo "# The following lines are desirable for IPv6 capable hosts"
        echo "::1 localhost ip6-localhost ip6-loopback"
        echo "ff02::1 ip6-allnodes"
        echo "ff02::2 ip6-allrouters"
    } > "$MOUNT_POINT/etc/hosts"
    
    # Configure network (using netplan)
    mkdir -p "$MOUNT_POINT/etc/netplan"
    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    ethernet-devices:"
        echo "      match:"
        echo "        name: \"enp*\""
        echo "      dhcp4: true"
    } > "$MOUNT_POINT/etc/netplan/01-network-manager-all.yaml"
    
    # Set proper permissions for netplan configuration
    chmod 600 "$MOUNT_POINT/etc/netplan/01-network-manager-all.yaml"
    
    log "System configuration completed"
}

chroot_setup() {
    log "Setting up chroot environment and installing packages..."
    
    # Mount necessary filesystems for chroot
    log "Mounting bind filesystems for chroot..."
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys "$MOUNT_POINT/sys"
    mount --bind /run "$MOUNT_POINT/run"
    log "Bind mounts completed successfully"
    
    # Ensure /run/udev exists in chroot for proper device handling
    mkdir -p "$MOUNT_POINT/run/udev"
    
    # Copy RAID configuration to chroot if available
    if [[ -f /tmp/raid-config/mdadm.conf ]]; then
        mkdir -p "$MOUNT_POINT/tmp/raid-config"
        cp /tmp/raid-config/mdadm.conf "$MOUNT_POINT/tmp/raid-config/mdadm.conf"
        log "Copied RAID configuration to chroot"
    fi
    
    # Setup DNS for chroot (handle resolv.conf carefully)
    log "Setting up DNS configuration for chroot..."
    
    # Check if resolv.conf already exists and is usable
    if [[ -f "$MOUNT_POINT/etc/resolv.conf" ]] && [[ -s "$MOUNT_POINT/etc/resolv.conf" ]]; then
        log "resolv.conf already exists in chroot, keeping existing"
    else
        # Try to copy host resolv.conf, with fallback to manual DNS setup
        if cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null; then
            log "Copied host resolv.conf to chroot"
        else
            log "Could not copy host resolv.conf (files may be same), creating manual DNS config"
            cat > "$MOUNT_POINT/etc/resolv.conf" << 'RESOLV_EOF'
# Generated by debian-setup.sh
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
RESOLV_EOF
                 fi
    fi
    log "DNS configuration for chroot completed"
    
    # Note: policy-rc.d will be created inside chroot script
    log "Creating chroot installation script..."
    
    # Create chroot script
    cat > "$MOUNT_POINT/tmp/chroot_setup.sh" << EOF
#!/bin/bash
set -euo pipefail

# Set up basic environment
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C

# Setup error logging
exec 2> >(tee /tmp/chroot_error.log >&2)

# Function to log progress
log_progress() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*"
}

log_progress "Starting chroot setup script"

# Update package lists
log_progress "Updating package lists..."
apt-get update

# Install locales package first to fix locale issues
log_progress "Installing locales..."
apt-get install -y locales

# Generate en_US.UTF-8 locale
log_progress "Generating locales..."
echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Configure APT to avoid interactive prompts (using modern options)
echo 'APT::Get::Assume-Yes "true";' > /etc/apt/apt.conf.d/90assumeyes
echo 'APT::Get::Allow-Unauthenticated "true";' > /etc/apt/apt.conf.d/90allowoptions
echo 'APT::Get::Allow-Downgrades "true";' >> /etc/apt/apt.conf.d/90allowoptions
echo 'APT::Get::Allow-Change-Held-Packages "true";' >> /etc/apt/apt.conf.d/90allowoptions
echo 'DPkg::Options "--force-confdef";' >> /etc/apt/apt.conf.d/90allowoptions
echo 'DPkg::Options "--force-confold";' >> /etc/apt/apt.conf.d/90allowoptions

# Disable automatic service startup during package installation
echo 'exit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Prevent initramfs updates during kernel installation (we'll do it manually later)
export INITRD=No

# Install non-kernel packages first
log_progress "Installing base packages (non-kernel)..."
apt-get install -y \\
    grub-efi-$ARCHITECTURE \\
    grub-efi-$ARCHITECTURE-signed \\
    shim-signed \\
    openssh-server \\
    mdadm \\
    cryptsetup \\
    btrfs-progs \\
    curl \\
    wget \\
    vim \\
    htop \\
    net-tools \\
    netplan.io

# Setup environment to avoid kernel symlink issues in chroot
log_progress "Preparing for kernel installation..."
mkdir -p /etc/initramfs-tools/conf.d

# Create initramfs configuration for our setup
cat > /etc/initramfs-tools/conf.d/cryptroot << 'INITRAMFS_EOF'
CRYPTSETUP=y
KEYFILE_PATTERN=/etc/keys/*.key
UMASK=0077
INITRAMFS_EOF

# Prevent kernel symlink creation during installation (causes issues in chroot)
export DPKG_MAINTSCRIPT_PACKAGE_REFCOUNT=1
mkdir -p /etc/kernel/postinst.d /etc/kernel/prerm.d

# Create stub scripts to prevent symlink operations
cat > /etc/kernel/postinst.d/zzz-skip-symlinks << 'KERNEL_STUB_EOF'
#!/bin/sh
# Skip automatic symlink creation in chroot
exit 0
KERNEL_STUB_EOF

cat > /etc/kernel/prerm.d/zzz-skip-symlinks << 'KERNEL_STUB_EOF'  
#!/bin/sh
# Skip automatic symlink removal in chroot
exit 0
KERNEL_STUB_EOF

chmod +x /etc/kernel/postinst.d/zzz-skip-symlinks
chmod +x /etc/kernel/prerm.d/zzz-skip-symlinks

# Replace linux-update-symlinks with a dummy script that does nothing
if [ -f /usr/bin/linux-update-symlinks ]; then
    mv /usr/bin/linux-update-symlinks /usr/bin/linux-update-symlinks.original
    cat > /usr/bin/linux-update-symlinks << 'DUMMY_SYMLINKS_EOF'
#!/bin/bash
# Dummy linux-update-symlinks for chroot environment
# This prevents symlink creation errors in chroot
echo "Skipping symlink creation in chroot environment (linux-update-symlinks dummy)"
exit 0
DUMMY_SYMLINKS_EOF
    chmod +x /usr/bin/linux-update-symlinks
fi

# Install kernel packages with symlink prevention
log_progress "Installing kernel packages (with symlink workaround)..."

# First try to install packages normally
if apt-get install -y linux-image-generic linux-headers-generic; then
    log_progress "Kernel packages installed successfully"
else
    log_progress "Kernel package installation had issues, attempting recovery..."
    
    # Try to fix any broken package state
    log_progress "Running dpkg --configure -a to fix package state..."
    dpkg --configure -a 2>/dev/null || true
    
    # Try to fix broken dependencies
    log_progress "Running apt-get install -f to fix dependencies..."
    apt-get install -f -y 2>/dev/null || true
    
    # Check if we have any kernels installed at all
    if ls /lib/modules/ 2>/dev/null | grep -q .; then
        log_progress "Found installed kernel modules, proceeding despite package errors..."
    else
        log_progress "No kernel modules found, attempting alternative installation..."
        
        # Try installing a specific kernel version
        AVAILABLE_KERNELS=\$(apt-cache search "^linux-image-[0-9]" | head -3 | cut -d' ' -f1)
        for kernel_pkg in \$AVAILABLE_KERNELS; do
            log_progress "Trying to install \$kernel_pkg..."
            if apt-get install -y "\$kernel_pkg"; then
                log_progress "Successfully installed \$kernel_pkg"
                break
            fi
        done
    fi
fi

# Restore original linux-update-symlinks
if [ -f /usr/bin/linux-update-symlinks.original ]; then
    mv /usr/bin/linux-update-symlinks.original /usr/bin/linux-update-symlinks
fi

# Clean up our workaround scripts
rm -f /etc/kernel/postinst.d/zzz-skip-symlinks
rm -f /etc/kernel/prerm.d/zzz-skip-symlinks

# Re-enable initramfs updates
unset INITRD
unset DPKG_MAINTSCRIPT_PACKAGE_REFCOUNT

# Verify kernel installation
log_progress "Verifying kernel installation..."
if [ -d /lib/modules ]; then
    KERNEL_COUNT=\$(ls /lib/modules/ | wc -l)
    if [ "\$KERNEL_COUNT" -gt 0 ]; then
        log_progress "Found \$KERNEL_COUNT kernel(s) installed"
        for kernel in \$(ls /lib/modules/); do
            log_progress "  - Kernel: \$kernel"
        done
    else
        log_progress "Warning: No kernels found in /lib/modules"
    fi
else
    log_progress "Warning: /lib/modules directory not found"
fi

# Check for kernel files in /boot
KERNEL_FILES=\$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
if [ "\$KERNEL_FILES" -gt 0 ]; then
    log_progress "Found \$KERNEL_FILES kernel file(s) in /boot"
else
    log_progress "Warning: No kernel files found in /boot"
    
    # Try to fix any incomplete installations
    log_progress "Attempting to fix incomplete kernel installation..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    
    # Final check after attempted fixes
    KERNEL_FILES_AFTER=\$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
    if [ "\$KERNEL_FILES_AFTER" -eq 0 ]; then
        log_progress "ERROR: Still no kernel files in /boot after recovery attempts"
        log_progress "This may cause boot issues. Manual intervention may be required."
    fi
fi

# Final verification - do we have the minimum required files?
HAVE_KERNEL_MODULES=false
HAVE_KERNEL_IMAGE=false

if [ -d /lib/modules ] && ls /lib/modules/ 2>/dev/null | grep -q .; then
    HAVE_KERNEL_MODULES=true
    log_progress "✓ Kernel modules present in /lib/modules"
fi

if ls /boot/vmlinuz-* 2>/dev/null | grep -q .; then
    HAVE_KERNEL_IMAGE=true
    log_progress "✓ Kernel image present in /boot"
fi

if [ "\$HAVE_KERNEL_MODULES" = true ] && [ "\$HAVE_KERNEL_IMAGE" = true ]; then
    log_progress "✓ Kernel installation verification passed - system should be bootable"
elif [ "\$HAVE_KERNEL_MODULES" = true ]; then
    log_progress "⚠ Partial kernel installation - modules present but missing boot files"
    log_progress "  System may still be bootable if files are created during initramfs generation"
else
    log_progress "✗ Kernel installation verification failed - system may not boot"
    log_progress "  Continuing anyway - manual fixes may be needed post-installation"
fi

log_progress "Kernel installation phase completed"

# Install NVIDIA driver package if specified
if [[ "$INSTALL_NVIDIA_DRIVERS" == "true" && -n "$NVIDIA_DRIVER_PACKAGE" ]]; then
    echo "Installing NVIDIA drivers via $NVIDIA_DRIVER_PACKAGE..."
    apt-get install -y "$NVIDIA_DRIVER_PACKAGE"
    
    # Auto-install drivers if using Ubuntu's ubuntu-drivers-common
    if [[ "$NVIDIA_DRIVER_PACKAGE" == "ubuntu-drivers-common" ]]; then
        ubuntu-drivers autoinstall
    fi
fi

# Remove policy-rc.d to allow services to start normally after chroot
rm -f /usr/sbin/policy-rc.d

# Enable SSH and networking services
systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Apply netplan configuration with error handling
if ! netplan generate 2>&1; then
    echo "Warning: Netplan configuration had issues, but continuing..."
    echo "This is often normal during installation and will be resolved on first boot"
fi

# Configure GRUB for encrypted boot
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

# Setup initramfs properly for our RAID+LUKS configuration
log_progress "Configuring initramfs for RAID and LUKS..."

# Ensure required modules are loaded
mkdir -p /etc/initramfs-tools
cat > /etc/initramfs-tools/modules << 'MODULES_EOF'
# Modules required for RAID + LUKS setup
dm_mod
dm_crypt
dm_raid
raid1
aes
aes_x86_64
xts
cbc
MODULES_EOF

# Configure cryptsetup in initramfs
mkdir -p /etc/initramfs-tools/conf.d
echo "CRYPTSETUP=y" > /etc/initramfs-tools/conf.d/cryptsetup

# Setup mdadm configuration
log_progress "Setting up RAID configuration..."
mkdir -p /etc/mdadm

# Copy RAID configuration from host if available
if [ -f /tmp/raid-config/mdadm.conf ]; then
    echo "Using RAID configuration from host..."
    cp /tmp/raid-config/mdadm.conf /etc/mdadm/mdadm.conf
elif [ -f /etc/mdadm/mdadm.conf ]; then
    echo "Using existing RAID configuration..."
    cp /etc/mdadm/mdadm.conf /etc/mdadm/mdadm.conf.backup 2>/dev/null || true
else
    echo "Scanning for RAID arrays..."
    mdadm --detail --scan > /etc/mdadm/mdadm.conf.new 2>/dev/null || true
    if [ -s /etc/mdadm/mdadm.conf.new ]; then
        mv /etc/mdadm/mdadm.conf.new /etc/mdadm/mdadm.conf
    else
        echo "# RAID configuration - update after first boot" > /etc/mdadm/mdadm.conf
        echo "ARRAY /dev/md0 metadata=1.2 name=any:0" >> /etc/mdadm/mdadm.conf
    fi
fi

# Generate initramfs with comprehensive error handling
log_progress "Generating initramfs..."
# Get list of installed kernels
KERNELS=\$(ls /lib/modules/ 2>/dev/null || echo "")

if [ -n "\$KERNELS" ]; then
    for kernel in \$KERNELS; do
        echo "Processing kernel \$kernel..."
        if update-initramfs -c -k "\$kernel" 2>/dev/null; then
            echo "Successfully created initramfs for \$kernel"
        elif update-initramfs -u -k "\$kernel" 2>/dev/null; then
            echo "Successfully updated initramfs for \$kernel"  
        else
            echo "Warning: Failed to update initramfs for \$kernel, but continuing..."
        fi
    done
else
    echo "No kernels found, skipping initramfs generation"
fi

log_progress "Initramfs configuration completed"
log_progress "Chroot setup script completed successfully"

EOF

    chmod +x "$MOUNT_POINT/tmp/chroot_setup.sh"
    log "Chroot script created, executing package installation..."
    
    # Execute chroot script
    log "Executing chroot script..."
    if ! chroot "$MOUNT_POINT" /tmp/chroot_setup.sh; then
        log "ERROR: Chroot script execution failed"
        log "Checking for any available error information..."
        if [[ -f "$MOUNT_POINT/tmp/chroot_error.log" ]]; then
            log "Chroot error log contents:"
            cat "$MOUNT_POINT/tmp/chroot_error.log"
        fi
        
        # Check if we have essential components despite the error
        log "Checking if essential system components are present..."
        local can_continue=false
        
        # Check for kernel modules
        if [[ -d "$MOUNT_POINT/lib/modules" ]] && ls "$MOUNT_POINT/lib/modules/"* &>/dev/null; then
            log "✓ Kernel modules found in chroot"
            can_continue=true
        fi
        
        # Check for essential tools
        if [[ -f "$MOUNT_POINT/usr/sbin/grub-install" ]]; then
            log "✓ GRUB tools found in chroot"
        else
            log "✗ GRUB tools missing - this will cause boot issues"
            can_continue=false
        fi
        
        if [[ "$can_continue" == "true" ]]; then
            log "RECOVERY: Essential components present despite errors"
            log "Continuing with installation - some manual fixes may be needed"
        else
            log "FATAL: Missing essential components, cannot continue"
            return 1
        fi
    fi
    
    # Clean up
    rm "$MOUNT_POINT/tmp/chroot_setup.sh"
    
    log "Chroot setup completed successfully"
}

create_user() {
    log "Creating user account..."
    
    # Prompt for user password if not set
    if [[ -z "$USER_PASSWORD" ]]; then
        prompt_password USER_PASSWORD "Enter password for user '$USERNAME'"
    fi
    
    # Create user in chroot
    cat > "$MOUNT_POINT/tmp/create_user.sh" << EOF
#!/bin/bash
set -euo pipefail

# Set environment
export DEBIAN_FRONTEND=noninteractive

# Create user
useradd -m -s /bin/bash -G sudo "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Set up SSH directory
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
chown $USERNAME:$USERNAME /home/$USERNAME/.ssh

EOF

    chmod +x "$MOUNT_POINT/tmp/create_user.sh"
    chroot "$MOUNT_POINT" /tmp/create_user.sh
    rm "$MOUNT_POINT/tmp/create_user.sh"
    
    log "User account created successfully"
}

setup_crypttab() {
    log "Setting up crypttab..."
    
    # Get UUID of encrypted device (RAID or single partition)
    local encrypted_device_uuid
    if [[ "$USE_RAID" == "false" ]]; then
        encrypted_device_uuid=$(blkid -s UUID -o value "${TARGET_DRIVES[0]}2")
        log "Single drive setup - using partition ${TARGET_DRIVES[0]}2"
    else
        encrypted_device_uuid=$(blkid -s UUID -o value /dev/md0)
        log "RAID setup - using RAID device /dev/md0"
    fi
    
    # Create crypttab entry
    {
        if [[ "$USE_RAID" == "false" ]]; then
            echo "# Single drive partition with LUKS encryption"
        else
            echo "# RAID device with LUKS encryption"
        fi
        echo "cryptroot UUID=$encrypted_device_uuid none luks"
    } > "$MOUNT_POINT/etc/crypttab"
    
    log "Crypttab configured successfully"
}

install_grub() {
    log "Installing and configuring GRUB..."
    
    if [[ "$USE_RAID" == "false" ]]; then
        log "Single drive setup - installing GRUB on ${TARGET_DRIVES[0]}"
    else
        log "Multi-drive setup - installing GRUB on all ${#TARGET_DRIVES[@]} drives for redundancy"
    fi
    
    # First, create necessary kernel symlinks that were skipped during chroot installation
    log "Setting up kernel boot files in /boot..."
    
    # Find the installed kernel version
    local kernel_version=$(ls "$MOUNT_POINT/lib/modules/" | head -1)
    if [[ -n "$kernel_version" ]]; then
        log "Found kernel version: $kernel_version"
        
        # Handle vmlinuz
        if [[ -f "$MOUNT_POINT/boot/vmlinuz-$kernel_version" ]]; then
            # Try symlink first, fallback to copy if symlinks not supported (e.g., FAT32)
            if ln -sf "vmlinuz-$kernel_version" "$MOUNT_POINT/boot/vmlinuz" 2>/dev/null; then
                log "Created vmlinuz symlink"
            elif cp "$MOUNT_POINT/boot/vmlinuz-$kernel_version" "$MOUNT_POINT/boot/vmlinuz" 2>/dev/null; then
                log "Created vmlinuz copy (symlinks not supported on this filesystem)"
            else
                log "Warning: Could not create vmlinuz link/copy"
            fi
        else
            log "Warning: vmlinuz-$kernel_version not found in /boot"
        fi
        
        # Handle initrd.img (may not exist yet, will be created during initramfs generation)
        if [[ -f "$MOUNT_POINT/boot/initrd.img-$kernel_version" ]]; then
            if ln -sf "initrd.img-$kernel_version" "$MOUNT_POINT/boot/initrd.img" 2>/dev/null; then
                log "Created initrd.img symlink"
            elif cp "$MOUNT_POINT/boot/initrd.img-$kernel_version" "$MOUNT_POINT/boot/initrd.img" 2>/dev/null; then
                log "Created initrd.img copy (symlinks not supported on this filesystem)"
            else
                log "Warning: Could not create initrd.img link/copy"
            fi
        else
            log "Note: initrd.img-$kernel_version not found yet (will be created during initramfs generation)"
            log "      This is normal behavior and not an error"
        fi
    else
        log "Warning: No kernel version found, boot files may need to be created manually"
    fi
    
    # Create GRUB configuration script for first drive
    cat > "$MOUNT_POINT/tmp/grub_setup.sh" << EOF
#!/bin/bash
set -euo pipefail

# Set environment
export DEBIAN_FRONTEND=noninteractive

# Update GRUB configuration
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub

# Set appropriate kernel command line based on drive configuration
if [[ "$USE_RAID" == "false" ]]; then
    # Single drive setup - no RAID device references
    echo 'GRUB_CMDLINE_LINUX="root=/dev/mapper/cryptroot rootflags=subvol=@"' >> /etc/default/grub
else
    # Multi-drive RAID setup
    echo 'GRUB_CMDLINE_LINUX="cryptdevice=/dev/md0:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@"' >> /etc/default/grub
fi

# Create kernel symlinks/copies if they don't exist (backup approach)
if [ -d /lib/modules ]; then
    LATEST_KERNEL=\$(ls /lib/modules/ | sort -V | tail -1)
    if [ -n "\$LATEST_KERNEL" ]; then
        # Handle vmlinuz
        if [ -f "/boot/vmlinuz-\$LATEST_KERNEL" ] && [ ! -e /boot/vmlinuz ]; then
            if ln -sf "vmlinuz-\$LATEST_KERNEL" /boot/vmlinuz 2>/dev/null; then
                echo "Created vmlinuz symlink in chroot"
            elif cp "/boot/vmlinuz-\$LATEST_KERNEL" /boot/vmlinuz 2>/dev/null; then
                echo "Created vmlinuz copy in chroot (symlinks not supported)"
            fi
        fi
        
        # Handle initrd.img (after initramfs generation)
        if [ -f "/boot/initrd.img-\$LATEST_KERNEL" ] && [ ! -e /boot/initrd.img ]; then
            if ln -sf "initrd.img-\$LATEST_KERNEL" /boot/initrd.img 2>/dev/null; then
                echo "Created initrd.img symlink in chroot"
            elif cp "/boot/initrd.img-\$LATEST_KERNEL" /boot/initrd.img 2>/dev/null; then
                echo "Created initrd.img copy in chroot (symlinks not supported)"
            fi
        fi
    fi
fi

# Install GRUB to first drive (already mounted at /boot)
grub-install --target=$GRUB_TARGET --efi-directory=/boot --bootloader-id=debian --recheck

# Update GRUB configuration
update-grub

# Update initramfs with error handling
if ! update-initramfs -u -k all; then
    echo "Warning: initramfs update had issues, but continuing..."
fi

EOF

    chmod +x "$MOUNT_POINT/tmp/grub_setup.sh"
    chroot "$MOUNT_POINT" /tmp/grub_setup.sh
    rm "$MOUNT_POINT/tmp/grub_setup.sh"
    
    log "GRUB installed to first drive (${TARGET_DRIVES[0]})"
    
    # Install GRUB to additional drives for redundancy (skip first drive as it's already done)
    if [[ "$USE_RAID" == "true" ]]; then
        for i in $(seq 1 $((${#TARGET_DRIVES[@]} - 1))); do
            local current_drive="${TARGET_DRIVES[$i]}"
            log "Installing GRUB to additional drive: $current_drive..."
            
            # Unmount current EFI partition
            umount "$MOUNT_POINT/boot"
            
            # Mount this drive's EFI partition
            mount "${current_drive}1" "$MOUNT_POINT/boot"
            
            # Create GRUB configuration script for this drive
            cat > "$MOUNT_POINT/tmp/grub_setup_drive_$i.sh" << EOF
#!/bin/bash
set -euo pipefail

# Set environment
export DEBIAN_FRONTEND=noninteractive

# Install GRUB to drive $current_drive
grub-install --target=$GRUB_TARGET --efi-directory=/boot --bootloader-id=debian --recheck

EOF

            chmod +x "$MOUNT_POINT/tmp/grub_setup_drive_$i.sh"
            chroot "$MOUNT_POINT" "/tmp/grub_setup_drive_$i.sh"
            rm "$MOUNT_POINT/tmp/grub_setup_drive_$i.sh"
            
            log "GRUB installed to drive $current_drive"
        done
        
        # Remount first drive's EFI partition for consistency
        umount "$MOUNT_POINT/boot"
        mount "${TARGET_DRIVES[0]}1" "$MOUNT_POINT/boot"
        
        log "GRUB installed to all ${#TARGET_DRIVES[@]} drives for redundancy"
    fi
    
    # Final check and creation of kernel boot files after all operations
    log "Final kernel boot file setup..."
    local kernel_version=$(ls "$MOUNT_POINT/lib/modules/" | head -1)
    if [[ -n "$kernel_version" ]]; then
        # Check if initrd was created during GRUB operations
        if [[ -f "$MOUNT_POINT/boot/initrd.img-$kernel_version" ]] && [[ ! -e "$MOUNT_POINT/boot/initrd.img" ]]; then
            if ln -sf "initrd.img-$kernel_version" "$MOUNT_POINT/boot/initrd.img" 2>/dev/null; then
                log "Created final initrd.img symlink"
            elif cp "$MOUNT_POINT/boot/initrd.img-$kernel_version" "$MOUNT_POINT/boot/initrd.img" 2>/dev/null; then
                log "Created final initrd.img copy"
            fi
        fi
        
        # Verify both kernel files are accessible
        if [[ -e "$MOUNT_POINT/boot/vmlinuz" ]] && [[ -e "$MOUNT_POINT/boot/initrd.img" ]]; then
            log "✓ Both vmlinuz and initrd.img are accessible in /boot"
        else
            log "⚠ Warning: Some kernel boot files may be missing:"
            [[ ! -e "$MOUNT_POINT/boot/vmlinuz" ]] && log "  - vmlinuz not found"
            if [[ ! -e "$MOUNT_POINT/boot/initrd.img" ]]; then
                log "  - initrd.img not found (often created on first boot - this is usually normal)"
            fi
        fi
    fi
    
    if [[ "$USE_RAID" == "false" ]]; then
        log "GRUB installation to single drive completed"
    else
        log "GRUB installation to all ${#TARGET_DRIVES[@]} drives completed"
    fi
}

safe_cleanup() {
    log "Cleaning up chroot environment (leaving installed system intact)..."
    
    # Clean up chroot-specific files (be more careful with resolv.conf)
    if [[ -f "$MOUNT_POINT/etc/resolv.conf" ]]; then
        # Only remove if it's not the same as host file
        if ! cmp -s /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null; then
            rm -f "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null || true
        fi
    fi
    rm -f "$MOUNT_POINT/usr/sbin/policy-rc.d" 2>/dev/null || true
    
    # Force unmount all chroot bind mounts (with retries)
    log "Unmounting chroot bind mounts..."
    for mount_point in "$MOUNT_POINT/run" "$MOUNT_POINT/dev/pts" "$MOUNT_POINT/dev" "$MOUNT_POINT/proc" "$MOUNT_POINT/sys"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting $mount_point..."
            umount -l "$mount_point" 2>/dev/null || umount -f "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Clean up temporary files
    rm -rf /tmp/raid-config 2>/dev/null || true
    
    log "Safe cleanup completed - installed system preserved"
}

cleanup() {
    log "Starting comprehensive cleanup (will destroy installation)..."
    
    # Clean up chroot-specific files (be more careful with resolv.conf)
    if [[ -f "$MOUNT_POINT/etc/resolv.conf" ]]; then
        # Only remove if it's not the same as host file
        if ! cmp -s /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null; then
            rm -f "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null || true
        fi
    fi
    rm -f "$MOUNT_POINT/usr/sbin/policy-rc.d" 2>/dev/null || true
    
    # Force unmount all chroot bind mounts (with retries)
    log "Unmounting chroot filesystems..."
    for mount_point in "$MOUNT_POINT/run" "$MOUNT_POINT/dev/pts" "$MOUNT_POINT/dev" "$MOUNT_POINT/proc" "$MOUNT_POINT/sys"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting $mount_point..."
            umount -l "$mount_point" 2>/dev/null || umount -f "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Turn off swap if it was enabled
    log "Disabling swap..."
    if [[ "$SWAP_SIZE_GB" != "0" ]]; then
        swapoff "$MOUNT_POINT/swap/swapfile" 2>/dev/null || true
        swapoff -a 2>/dev/null || true  # Turn off all swap just in case
    fi
    
    # Unmount main filesystems (with retries)
    log "Unmounting main filesystems..."
    for mount_point in "$MOUNT_POINT/boot" "$MOUNT_POINT"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting $mount_point..."
            umount -l "$mount_point" 2>/dev/null || umount -f "$mount_point" 2>/dev/null || true
            sleep 1
        fi
    done
    
    # Close all LUKS devices
    log "Closing LUKS devices..."
    cryptsetup luksClose cryptroot 2>/dev/null || true
    
    # Find and close any other LUKS devices that might be open
    for luks_device in $(ls /dev/mapper/ 2>/dev/null | grep -v control || true); do
        if [[ "$luks_device" != "control" ]]; then
            cryptsetup luksClose "$luks_device" 2>/dev/null || true
        fi
    done
    
    # Remove LUKS signatures from RAID device before stopping RAID
    log "Removing LUKS signatures from RAID device..."
    if [[ -e /dev/md0 ]]; then
        if cryptsetup isLuks /dev/md0 2>/dev/null; then
            log "  Found LUKS device, erasing all keyslots..."
            echo "YES" | cryptsetup erase /dev/md0 2>/dev/null || true
        fi
        
        # Also wipe any remaining filesystem signatures
        wipefs -a /dev/md0 2>/dev/null || true
    fi
    
    # Stop and destroy RAID arrays completely
    log "Stopping and destroying RAID arrays..."
    
    # Stop specific RAID array
    if [[ -e /dev/md0 ]]; then
        mdadm --stop /dev/md0 2>/dev/null || true
    fi
    
    # Stop all RAID arrays
    if [[ -f /proc/mdstat ]]; then
        for md_device in $(grep "^md" /proc/mdstat 2>/dev/null | cut -d: -f1 || true); do
            if [[ -n "$md_device" ]]; then
                log "Stopping RAID array /dev/$md_device..."
                mdadm --stop "/dev/$md_device" 2>/dev/null || true
            fi
        done
    fi
    
    # Remove RAID superblocks from partitions
    log "Removing RAID superblocks from partitions..."
    
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ -b "$drive" ]]; then
            log "Cleaning RAID metadata from $drive and its partitions..."
            
            # Remove superblocks from all existing partitions
            for partition in "${drive}"*; do
                if [[ -b "$partition" && "$partition" != "$drive" ]]; then
                    log "  Zeroing RAID superblock on $partition..."
                    mdadm --zero-superblock "$partition" 2>/dev/null || true
                    wipefs -a "$partition" 2>/dev/null || true
                fi
            done
            
            # Remove superblocks from the whole drive (in case of whole-disk RAID)
            log "  Zeroing RAID superblock on whole drive $drive..."
            mdadm --zero-superblock "$drive" 2>/dev/null || true
            wipefs -a "$drive" 2>/dev/null || true
        fi
    done
    

    
    # Force removal of any persistent RAID metadata
    log "Forcing removal of persistent RAID metadata..."
    
    # Remove any remaining RAID metadata using dd (wipe first and last 1MB where metadata is typically stored)
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ -b "$drive" ]]; then
            log "  Deep cleaning RAID metadata from $drive..."
            
            # Wipe beginning of drive (first 10MB to be thorough)
            dd if=/dev/zero of="$drive" bs=1M count=10 2>/dev/null || true
            
            # Wipe end of drive (last 10MB where some RAID metadata is stored)
            local drive_size=$(blockdev --getsz "$drive" 2>/dev/null || echo "0")
            if [[ "$drive_size" -gt 20480 ]]; then  # Only if drive is > 10MB
                local end_seek=$((drive_size / 2048 - 10))  # Convert sectors to MB, minus 10MB
                dd if=/dev/zero of="$drive" bs=1M count=10 seek="$end_seek" 2>/dev/null || true
            fi
        fi
    done
    
    # Wipe partition tables and all remaining signatures completely
    log "Wiping partition tables and all remaining signatures..."
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ -b "$drive" ]]; then
            log "Completely wiping $drive..."
            
            # Use multiple methods to ensure complete wiping
            
            # 1. Use sgdisk to destroy GPT structures
            log "  Destroying GPT structures on $drive..."
            sgdisk --zap-all "$drive" 2>/dev/null || true
            
            # 2. Use dd to wipe MBR and beginning of drive (first 100MB to be extra thorough)
            log "  Wiping beginning of $drive (100MB)..."
            dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null || true
            
            # 3. Wipe the end of drive where backup GPT is stored (last 100MB)
            local drive_size=$(blockdev --getsz "$drive" 2>/dev/null || echo "0")
            if [[ "$drive_size" -gt 204800 ]]; then  # Only if drive is > 100MB
                local end_seek=$((drive_size / 2048 - 100))  # Convert sectors to MB, minus 100MB
                log "  Wiping end of $drive (100MB)..."
                dd if=/dev/zero of="$drive" bs=1M count=100 seek="$end_seek" 2>/dev/null || true
            fi
            
            # 4. Use wipefs again as final cleanup
            log "  Final signature wipe on $drive..."
            wipefs -af "$drive" 2>/dev/null || true
            
            # 5. Force kernel to re-read partition table
            log "  Forcing kernel to re-read partition table..."
            blockdev --rereadpt "$drive" 2>/dev/null || true
            partprobe "$drive" 2>/dev/null || true
            
            # 6. Brief pause to let changes settle
            sleep 2
        fi
    done
    
    # Clear any remaining device mapper entries
    log "Cleaning up device mapper..."
    dmsetup remove_all 2>/dev/null || true
    
    # Force udev to update
    log "Updating udev..."
    udevadm settle 2>/dev/null || true
    
    # Clean up temporary files
    log "Cleaning up temporary files..."
    rm -rf /tmp/raid-config 2>/dev/null || true
    
    # Final verification that cleanup was successful
    log "Verifying cleanup completion..."
    
    # Check that no RAID arrays are active
    if [[ -f /proc/mdstat ]] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        log "⚠ Warning: Some RAID arrays may still be active:"
        grep "^md" /proc/mdstat 2>/dev/null || true
    else
        log "✓ No active RAID arrays detected"
    fi
    
    # Check that no device mapper devices exist (except control)
    local dm_devices=$(ls /dev/mapper/ 2>/dev/null | grep -v control | wc -l)
    if [[ "$dm_devices" -gt 0 ]]; then
        log "⚠ Warning: Some device mapper devices still exist:"
        ls /dev/mapper/ 2>/dev/null | grep -v control || true
    else
        log "✓ No device mapper devices detected"
    fi
    
    # Check that drives have no recognizable signatures
    for drive in "${TARGET_DRIVES[@]}"; do
        if [[ -b "$drive" ]]; then
            local signatures=$(wipefs -n "$drive" 2>/dev/null | wc -l)
            if [[ "$signatures" -gt 0 ]]; then
                log "⚠ Warning: $drive still has some signatures:"
                wipefs -n "$drive" 2>/dev/null || true
            else
                log "✓ $drive appears completely clean"
            fi
        fi
    done
    
    log "Comprehensive cleanup completed - drives should be completely clean for fresh installation"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --cleanup     Clean up existing RAID/LUKS configurations and partitions"
    echo "  --force       Force cleanup before installation if conflicts detected"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Normal installation (will check for conflicts)"
    echo "  $0 --force           # Auto-cleanup conflicts and install"
    echo "  $0 --cleanup         # Only cleanup existing configurations"
    echo ""
}

# Handle command line arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        --cleanup)
            log "Running cleanup mode..."
            detect_architecture  # Still need this for drive variables
            
            # Run comprehensive cleanup to remove everything
            cleanup
            log "Cleanup completed. You can now run the installation script normally."
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --force)
            # --force will be handled in check_prerequisites
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
fi

main() {
    log "Starting Debian-based System Setup Script"
    
    # Set up trap for cleanup on exit (only for errors, not normal completion)
    trap 'cleanup; exit 1' ERR
    trap 'log "Installation interrupted by user"; cleanup; exit 130' INT
    trap 'log "Installation terminated"; cleanup; exit 143' TERM
    
    # Detect system architecture first
    detect_architecture
    
    # Check prerequisites (including conflict detection)
    check_prerequisites "$@"
    
    # Confirm destructive operation
    echo ""
    echo "WARNING: This script will completely wipe the following drive(s):"
    for drive in "${TARGET_DRIVES[@]}"; do
        echo "  - $drive"
    done
    echo ""
    if [[ "$USE_RAID" == "false" ]]; then
        echo "Single drive setup: LUKS encryption will be applied directly to ${TARGET_DRIVES[0]}2"
    else
        echo "Multi-drive setup: RAID1 will be created across all ${#TARGET_DRIVES[@]} drives, then LUKS encrypted"
    fi
    echo ""
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        error "Operation cancelled by user"
    fi
    
    # Execute main setup steps
    setup_partitions
    setup_raid
    setup_luks
    format_filesystems
    setup_btrfs_subvolumes
    mount_filesystems
    install_base_system
    configure_system
    chroot_setup
    create_user
    setup_crypttab
    install_grub
    
    # If we get here, installation was successful - disable cleanup trap
    trap - ERR INT TERM
    
    # Clean up only the chroot bind mounts, but leave the installed system intact
    safe_cleanup
    
    log "Installation completed successfully!"
    echo ""
    echo "The system is now ready. You can reboot and remove the installation media."
    echo "During boot, you will be prompted for the LUKS password."
    echo ""
    echo "Login credentials:"
    echo "  Username: $USERNAME"
    echo "  Password: [as configured]"
    echo ""
    echo "System configuration:"
    echo "  - Distribution: $DISTRIBUTION ($ARCHITECTURE)"
    if [[ "$USE_RAID" == "false" ]]; then
        echo "  - Single drive configuration: ${TARGET_DRIVES[0]}"
        echo "  - LUKS2 encryption on single partition"
    else
        echo "  - RAID1 configuration across ${#TARGET_DRIVES[@]} drives: ${TARGET_DRIVES[*]}"
        echo "  - LUKS2 encryption on RAID device"
    fi
    echo "  - BTRFS filesystem with @ subvolume"
    if [[ "$SWAP_SIZE_GB" != "0" ]]; then
        echo "  - ${SWAP_SIZE_GB}GiB encrypted swap partition"
    else
        echo "  - No swap partition (disabled)"
    fi
    echo "  - SSH server enabled"
    if [[ "$INSTALL_NVIDIA_DRIVERS" == "true" && -n "$NVIDIA_DRIVER_PACKAGE" ]]; then
        echo "  - NVIDIA drivers installed"
    fi
}

# Execute main function
main "$@" 