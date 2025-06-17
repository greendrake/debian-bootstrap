# Debian-based System Setup Script

This script implements a complete installation of any Debian-based system with LUKS2 encryption and BTRFS filesystem. It works with Ubuntu, Debian, and other derivatives supported by debootstrap.

If 2 or more hard drives are provided, it will create a RAID1 device above the LUKS device.

I created this script because I was unable to arrange the required configuration using out-of-the-box installers.

## Features

- **UEFI Boot**: Proper GPT partitioning with EFI system partition
- **RAID1**: Software RAID across two identical drives
- **LUKS2 Encryption**: Single encrypted device on RAID1 array
- **BTRFS**: Modern filesystem with multiple subvolumes (@, @home, @var, @swap, @snapshots)
- **Minimal System**: SSH server + optional NVIDIA drivers
- **Secure Boot**: GRUB configured for encrypted boot
- **Multi-Architecture**: Auto-detects system architecture (amd64, arm64)

## System Architecture

```
Drive 1 (/dev/sda)          Drive 2 (/dev/sdb)
├── sda1 (512MiB EFI)       ├── sdb1 (512MiB EFI)
└── sda2 (RAID member)      └── sdb2 (RAID member)
                                    │
                            ┌───────┴───────┐
                            │   OPTIONAL    │
                            │   /dev/md0    │
                            │   (RAID1)     │
                            └───────┬───────┘
                                    │
                            ┌───────┴───────┐
                            │   LUKS2       │
                            │  (cryptroot)  │
                            └───────┬───────┘
                                    │
                            ┌───────┴───────┐
                            │     BTRFS     │
                            │  (compressed) │
                            └───────┬───────┘
                                    │
        ┌───────────────┬───────────┼───────────┬───────────────┐
        │               │           │           │               │
┌───────┴───────┐ ┌─────┴─────┐ ┌───┴───┐ ┌─────┴─────┐ ┌───────┴───────┐
│ @ (root)      │ │ @home     │ │ @var  │ │ @swap     │ │ @snapshots    │
│ /             │ │ /home     │ │ /var  │ │ /swap     │ │ /.snapshots   │
│               │ │           │ │       │ │ swapfile  │ │               │
└───────────────┘ └───────────┘ └───────┘ └───────────┘ └───────────────┘
```

**BTRFS Design**: The system uses a single LUKS-encrypted BTRFS filesystem with multiple subvolumes for better organization:

- **@ (root)**: System files, can be snapshotted independently for rollback capability
- **@home**: User data, isolated for separate backup/snapshot policies  
- **@var**: Logs and variable data, separated to avoid including in system snapshots
- **@swap**: Swapfile location, excluded from snapshots to avoid backup bloat
- **@snapshots**: Dedicated space for storing BTRFS snapshots (when created manually)

**Note**: The script creates the subvolume structure but does not configure automatic snapshotting. Snapshots must be created manually using `btrfs subvolume snapshot` commands.

**Compression**: All subvolumes use ZSTD compression for space efficiency and improved performance on modern storage.

## Prerequisites

1. Boot from any Debian-based live system (Ubuntu, Debian, etc.)
2. At least one free-to-wipe hard drive connected
3. Run the script as root
4. Ensure the system has internet connectivity

## Supported Distributions

- **Ubuntu**: noble, jammy, focal, etc.
- **Debian**: bookworm, bullseye, sid, etc.
- **Other**: Any Debian derivative supported by debootstrap

Tested on Ubuntu 24 only.


## Usage

1. **Configure the script** (optional):
   ```bash
   nano debian-setup.sh
   ```
   Edit the configuration variables at the top:
   - `TARGET_DRIVES`: Drive paths (default: `/dev/sda`, `/dev/sdb`)
   - `HOSTNAME`: System hostname (default: `black`)
   - `USERNAME`: User account name (default: `user`)
   - `SWAP_SIZE_GB`: Swapfile size in GiB (default: `32`, set to `0` to disable)
   - `DISTRIBUTION`: Target distribution (default: `noble`)
   - `ARCHIVE_URL`: Package archive URL (default: Ubuntu's archive)
   - `NVIDIA_DRIVER_PACKAGE`: NVIDIA driver package name (Ubuntu: `ubuntu-drivers-common`, Debian: `nvidia-driver`)
   - `INSTALL_NVIDIA_DRIVERS`: Set to `false` to skip NVIDIA drivers
   - `LUKS_PASSWORD` and `USER_PASSWORD`: Leave empty to be prompted

2. **Configuration Examples**:

   **For Ubuntu (default)**:
   ```bash
   DISTRIBUTION="noble"
   ARCHIVE_URL="http://archive.ubuntu.com/ubuntu/"
   NVIDIA_DRIVER_PACKAGE="ubuntu-drivers-common"
   ```

   **For Debian**:
   ```bash
   DISTRIBUTION="bookworm"
   ARCHIVE_URL="http://deb.debian.org/debian/"
   NVIDIA_DRIVER_PACKAGE="nvidia-driver"
   ```

   **No NVIDIA drivers**:
   ```bash
   INSTALL_NVIDIA_DRIVERS="false"
   ```

3. **Run the installation**:
   ```bash
   sudo ./debian-setup.sh
   ```

   **Options available**:
   - `sudo ./debian-setup.sh` - Normal installation (checks for conflicts)
   - `sudo ./debian-setup.sh --force` - Auto-cleanup conflicts and install
   - `sudo ./debian-setup.sh --cleanup` - Only cleanup existing configurations
   - `sudo ./debian-setup.sh --help` - Show usage information

4. **Follow the prompts**:
   - Confirm drive wiping (type `yes`)
   - Enter LUKS2 encryption password
   - Enter user account password

5. **Wait for completion** (typically 30-60 minutes depending on hardware)

6. **Reboot and remove installation media**

## Post-Installation

After reboot:
- You'll be prompted for the LUKS password
- System will boot to the encrypted installation
- SSH server will be running
- NVIDIA drivers will be installed (if configured)
- Login with the configured username/password

## Configuration Details

- **Partition Layout**: GPT with 512MiB EFI + RAID partition
- **RAID**: mdadm RAID1 with `/dev/md0` (when 2 or more hard drives configured)
- **Encryption**: LUKS2 with AES-XTS-PLAIN64, 512-bit key, Argon2id
- **Filesystem**: BTRFS with multiple subvolumes (@, @home, @var, @swap, @snapshots) and ZSTD compression
- **Boot**: GRUB with cryptodisk support, installed on both drives
- **Architecture**: Auto-detected (amd64, arm64 supported)
- **Network**: DHCP via netplan

## Safety Features

- Comprehensive prerequisite checking
- User confirmation before destructive operations
- Automatic cleanup on script exit
- Detailed logging with timestamps
- Error handling with descriptive messages

## Troubleshooting

If the script fails:
1. Check the log messages for specific errors
2. Ensure all prerequisites are met
3. Verify drive paths are correct
4. Check internet connectivity for package downloads
5. The cleanup function should automatically unmount/close everything

### Common Issues

**"Device or resource busy" errors**:
If you get `mdadm: cannot open /dev/sda2: Device or resource busy`, this means there are leftover RAID/LUKS configurations from a previous run. The script includes comprehensive cleanup that removes:

- All RAID arrays and superblocks (from partitions and whole drives)
- All LUKS/device-mapper devices  
- All filesystem signatures (using `wipefs`)
- All partition table structures (GPT and MBR)
- First and last 100MB of each drive (where metadata is stored)

Solutions:

```bash
# Option 1: Run cleanup only
sudo ./debian-setup.sh --cleanup

# Option 2: Force cleanup and continue with installation
sudo ./debian-setup.sh --force

# Option 3: Manual cleanup (if script cleanup fails)
sudo umount -a                           # Unmount everything
sudo swapoff -a                          # Turn off swap  
sudo cryptsetup luksClose cryptroot      # Close LUKS devices
sudo mdadm --stop --scan                 # Stop all RAID arrays
sudo mdadm --zero-superblock /dev/sda*   # Remove RAID superblocks from partitions
sudo mdadm --zero-superblock /dev/sdb*
sudo mdadm --zero-superblock /dev/sda    # Remove from whole drives
sudo mdadm --zero-superblock /dev/sdb
sudo wipefs -af /dev/sda                 # Remove all filesystem signatures  
sudo wipefs -af /dev/sdb
sudo sgdisk --zap-all /dev/sda          # Wipe partition tables
sudo sgdisk --zap-all /dev/sdb
sudo dd if=/dev/zero of=/dev/sda bs=1M count=100  # Zero beginning and end
sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100
```

**Package installation errors**:
The script includes comprehensive error handling for kernel packages and chroot environment issues. Check the detailed logs for specific package failures.

## Security Notes

- LUKS2 password is required on every boot
- SSH server is enabled but requires key-based or password authentication
- User account has sudo privileges
- System uses secure boot with signed GRUB/shim

## Distribution Examples

**Ubuntu 24.04 LTS (Noble)**:
```bash
DISTRIBUTION="noble"
ARCHIVE_URL="http://archive.ubuntu.com/ubuntu/"
```

**Ubuntu 22.04 LTS (Jammy)**:
```bash
DISTRIBUTION="jammy"
ARCHIVE_URL="http://archive.ubuntu.com/ubuntu/"
```

**Debian 12 (Bookworm)**:
```bash
DISTRIBUTION="bookworm"
ARCHIVE_URL="http://deb.debian.org/debian/"
NVIDIA_DRIVER_PACKAGE="nvidia-driver"
```

**Debian Unstable (Sid)**:
```bash
DISTRIBUTION="sid"
ARCHIVE_URL="http://deb.debian.org/debian/"
NVIDIA_DRIVER_PACKAGE="nvidia-driver"
```

**Warning**: This script will completely wipe the target drives. Ensure you have backups of any important data. 