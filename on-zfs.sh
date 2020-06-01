#!/bin/bash

# shellcheck disable=SC2015,SC2016,SC2034

# Shellcheck issue descriptions:
#
# - SC2015: <condition> && <operation> || true
# - SC2016: annoying warning about using single quoted strings with characters
#           used for interpolation
# - SC2034: triggers a bug on the `-v` test (see https://git.io/Jenyu)

set -o errexit   # コマンドがエラーになったらただちにシェルを終了
set -o pipefail  # パイプの途中のエラーを検出してその終了コードを返す

# $1 が "" ならば fbterm をインストールして fbterm 内で再実行
if [ " $1" = " " ]; then
	apt update
	apt full-upgrade -y
	apt install -y fbterm
	fbterm -- ./on-zfs.sh main
	exit
fi

# 設定されていない変数があればエラー
# $1 が "" だとエラーになるのでこの位置
set -o nounset

# VARIABLES/CONSTANTS ##########################################################

# Variables set by the script

linux_distribution=  # Ubuntu, ... WATCH OUT: not necessarily from `lsb_release` (ie. UbuntuServer)

# Variables set (indirectly) by the user
#
# The passphrase has a special workflow - it's sent to a named pipe (see create_passphrase_named_pipe()).
# The same strategy can possibly be used for `v_root_passwd` (the difference being that is used
# inside a jail); logging the ZFS commands is enough, for now.
#
# Note that `ZFS_PASSPHRASE` and `ZFS_POOLS_RAID_TYPE` consider the unset state (see help).

selected_disk=  # /dev/disk/by-id/...
swap_size=
bpool_name=bpool
v_bpool_tweaks=              # array; see defaults below for format
rpool_name=rpool
v_rpool_tweaks=              # array; see defaults below for format

# Variables set during execution

v_temp_volume_device=        # /dev/zdN; scope: setup_partitions -> sync_os_temp_installation_dir_to_rpool

# Constants

c_default_bpool_tweaks=
c_default_rpool_tweaks=
c_zfs_mount_dir=/mnt
c_installed_os_data_mount_dir=/target
declare -A c_supported_linux_distributions=([Ubuntu]="20.04" [UbuntuServer]="20.04")
EFI_SYSTEM_PARTITION_SIZE=1G
BPOOL_PARTITION_SIZE=1G
TEMPORARY_VOLUME_SIZE=12G  # large enough; Debian, for example, takes ~8 GiB.

c_log_dir=$(mktemp -dp /tmp on-zfs_XXX)  # e.g. /tmp/on-zfs_xyz
c_install_log=$c_log_dir/install.log
c_os_information_log=$c_log_dir/os_information.log
c_running_processes_log=$c_log_dir/running_processes.log
c_disks_log=$c_log_dir/disks.log
c_zfs_module_version_log=$c_log_dir/updated_module_versions.log

# On a system, while installing Ubuntu 18.04(.4), all the `udevadm settle` invocations timed out.
#
# It's not clear why this happens, so we set a large enough timeout. On systems without this issue,
# the timeout won't matter, while on systems with the issue, the timeout will be enough to ensure
# that the devices are created.
#
# Note that the strategy of continuing in any case (`|| true`) is not the best, however, the exit
# codes are not documented.
#
c_udevadm_settle_timeout=10 # seconds

function main {
	stage1
	stage2
}

function stage1 {
	apt update
	apt full-upgrade -y
	apt install -y python-is-python3

	activate_debug
	set_distribution_data
	store_os_distro_information
	store_running_processes
	check_prerequisites

	display_intro_banner

	select_disk
	ask_swap_size
	ask_pool_tweaks

	install_host_packages
	setup_partitions

	# Includes the O/S extra configuration, if necessary (network, root pwd, etc.)
	if [[ $linux_distribution = "Ubuntu" ]]; then
		install_operating_system
	else
		install_operating_system_UbuntuServer
	fi
}

function stage2 {
	create_pools
	create_zfs_partitions
	sync_os_temp_installation_dir_to_rpool
	remove_temp_partition_and_expand_rpool

	prepare_jail
	install_jail_zfs_packages
	install_and_configure_bootloader
	configure_boot_pool_import
	configure_pools_trimming
	configure_remaining_settings

	prepare_for_system_exit
	display_exit_banner
}

# HELPER FUNCTIONS #############################################################

# shellcheck disable=SC2120 # allow parameters passing even if no calls pass any
function print_step_info_header {
  echo -n "
###############################################################################
# $1"

  [ "${1:-}" != "" ] && echo -n " $1" || true

  echo "
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "$1"
}

# PROCEDURE STEP FUNCTIONS #####################################################

function display_help_and_exit {
	local help='Usage: on-zfs.sh [help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_ENCRYPT_RPOOL          : set 1 to encrypt the pool
- ZFS_PASSPHRASE             : set non-blank to encrypt the pool, and blank not to. if unset, it will be asked.
- ZFS_DEBIAN_ROOT_PASSWORD
- ZFS_BPOOL_NAME
- ZFS_RPOOL_NAME
- ZFS_BPOOL_TWEAKS           : boot pool options to set on creation (defaults to `'$c_default_bpool_tweaks'`)
- ZFS_RPOOL_TWEAKS           : root pool options to set on creation (defaults to `'$c_default_rpool_tweaks'`)
- ZFS_POOLS_RAID_TYPE        : options: blank (striping), `mirror`, `raidz`, `raidz2`, `raidz3`; if unset, it will be asked.
- ZFS_NO_INFO_MESSAGES       : set 1 to skip informational messages
- ZFS_SWAP_SIZE              : swap size (integer); set 0 for no swap
- ZFS_FREE_TAIL_SPACE        : leave free space at the end of each disk (integer), for example, for a swap partition

- ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL : (debug) set 1 to skip installing the ZFS package on the live system; speeds up installation on preset machines

When installing the O/S via $ZFS_OS_INSTALLATION_SCRIPT, the root pool is mounted as `'$c_zfs_mount_dir'`; the requisites are:

1. the virtual filesystems must be mounted in `'$c_zfs_mount_dir'` (ie. `for vfs in proc sys dev; do mount --rbind /$vfs '$c_zfs_mount_dir'/$vfs; done`)
2. internet must be accessible while chrooting in `'$c_zfs_mount_dir'` (ie. `echo nameserver 8.8.8.8 >> '$c_zfs_mount_dir'/etc/resolv.conf`)
3. `'$c_zfs_mount_dir'` must be left in a dismountable state (e.g. no file locks, no swap etc.);
'

  echo "$help"

  exit 0
}

function activate_debug {
  print_step_info_header activate_debug

  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

function set_distribution_data {
	linux_distribution="$(lsb_release --id --short)"

	if [[ "$linux_distribution" == "Ubuntu" ]] && grep -q '^Status: install ok installed$' < <(dpkg -s ubuntu-server 2> /dev/null); then
		linux_distribution="UbuntuServer"
	fi

	v_linux_version="$(lsb_release --release --short)"
}

function store_os_distro_information {
  print_step_info_header store_os_distro_information

  lsb_release --all > "$c_os_information_log"

  # Madness, in order not to force the user to invoke "sudo -E".
  # Assumes that the user runs exactly `sudo bash`; it's not a (current) concern if the user runs off specification.
  # Not found when running via SSH - inspect the processes for finding this information.
  #
  perl -lne 'BEGIN { $/ = "\0" } print if /^XDG_CURRENT_DESKTOP=/' /proc/"$PPID"/environ >> "$c_os_information_log"
}

# Simplest and most solid way to gather the desktop environment (!).
# See note in store_os_distro_information().
#
function store_running_processes {
  ps ax --forest > "$c_running_processes_log"
}

function check_prerequisites {
  print_step_info_header check_prerequisites

  local distro_version_regex=\\b${v_linux_version//./\\.}\\b

  # shellcheck disable=SC2116 # `=~ $(echo ...)` causes a warning; see https://git.io/Je2QP.
  #
  if [ ! -d /sys/firmware/efi ]; then
    echo 'System firmware directory not found; make sure to boot in EFI mode!'
    exit 1
  elif [ $(id -u) -ne 0 ]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  elif [ "${ZFS_OS_INSTALLATION_SCRIPT:-}" != "" && ! -x "$ZFS_OS_INSTALLATION_SCRIPT" ]; then
    echo "The custom O/S installation script provided doesn't exist or is not executable!"
    exit 1
  elif [ ! -v c_supported_linux_distributions["$linux_distribution"] ]; then
    echo "This Linux distribution ($linux_distribution) is not supported!"
    exit 1
  elif [ ! ${c_supported_linux_distributions["$linux_distribution"]} =~ $distro_version_regex ]; then
    echo "This Linux distribution version ($v_linux_version) is not supported; supported versions: ${c_supported_linux_distributions["$linux_distribution"]}"
    exit 1
  fi

  set +x

  if [ -v ZFS_PASSPHRASE && -n $ZFS_PASSPHRASE && ${#ZFS_PASSPHRASE} -lt 8 ]; then
    echo "The passphase provided is too short; at least 8 chars required."
    exit 1
  fi

  set -x
}

function display_intro_banner {
  print_step_info_header display_intro_banner

  local dialog_message='Hello!

This script will prepare the ZFS pools on the system, install Ubuntu, and configure the boot.

In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'

	whiptail --msgbox "$dialog_message" 30 100
}

function select_disk {
	print_step_info_header select_disk

	# In some freaky cases, `/dev/disk/by-id` is not up to date, so we refresh. One case is
	# after starting a VirtualBox VM that is a full clone of a suspended VM with snapshots.
	udevadm trigger

	# shellcheck disable=SC2012 # `ls` may clean the output, but in this case, it doesn't matter
	ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

	# Iterating via here-string generates an empty line when no devices are found.
	# The options are either using this strategy, or adding a conditional.
	local candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi|mmc)-.+' -not -regex '.+-part[0-9]+$' | sort)
	local mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"
	local suitable_disks=()  # /dev/disk/by-id/...

	while read -r disk_id || [ -n "$disk_id" ]; do
		local device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
		local block_device_basename="$(basename "$(readlink -f "$disk_id")")"

		# It's unclear
		# if it's possible to establish with certainty what is an internal disk:
		#
		# - there is no (obvious) spec around
		# - pretty much everything has `DEVTYPE=disk`, e.g. LUKS devices
		# - ID_TYPE is optional
		#
		# Therefore, it's probably best to rely on the id name,
		# and just filter out optical devices.
		if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then  # 光学ドライブではない
			# マウントされていない
			if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
				suitable_disks+=("$disk_id")
			fi
		fi

		cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG

	done < <(echo -n "$candidate_disk_ids")

	if [ ${#suitable_disks[@]} -eq 0 ]; then
		local dialog_message='No suitable disks have been found!

If you'\''re running inside a VMWare virtual machine, you need to add set `disk.EnableUUID = "TRUE"` in the .vmx configuration file.

If you think this is a bug, please open an issue on https://github.com/taku-n/on-zfs/issues, and attach the file `'"$c_disks_log"'`.
'
		whiptail --msgbox "$dialog_message" 30 100

		exit 1
	fi

	print_variables suitable_disks

	local menu_entries_option

	for disk_id in "${suitable_disks[@]}"; do
		local block_device_basename="$(basename "$(readlink -f "$disk_id")")"
		menu_entries_option+=("$disk_id" "($block_device_basename)")
	done

	local dialog_message="ZFS を構築するデバイスを選択してください。
#
#Devices with mounted partitions, cdroms, and removable devices are not displayed!
#"
	selected_disk=$(whiptail --menu --separate-output "$dialog_message" 30 100 10 "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

	print_variables selected_disk
}

function ask_swap_size {
	print_step_info_header ask_swap_size

	local swap_size_invalid_message=

	while [[ ! $swap_size =~ ^[0-9]+$ ]]; do
		swap_size=$(whiptail --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):
(0 は現在非対応です)" 30 100 2 3>&1 1>&2 2>&3)

		swap_size_invalid_message="Invalid swap size! "
	done

	swap_size=${swap_size}G

	print_variables swap_size
}

function ask_pool_tweaks {
	print_step_info_header ask_pool_tweaks

	v_bpool_tweaks=$(whiptail --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)

	v_rpool_tweaks=${ZFS_RPOOL_TWEAKS:-$(whiptail --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)}

	print_variables v_bpool_tweaks v_rpool_tweaks
}

function install_host_packages {
	print_step_info_header install_host_packages

	apt install -y efibootmgr zfsutils-linux

	zfs --version > "$c_zfs_module_version_log" 2>&1
}

function setup_partitions {
	print_step_info_header setup_partitions

	# More thorough than `sgdisk --zap-all`.
	#
	wipefs --all "$selected_disk"

	sgdisk -n 1:1M:+"$EFI_SYSTEM_PARTITION_SIZE" -t 1:EF00 "$selected_disk" # EFI System
	sgdisk -n 2::+"$swap_size"                   -t 2:8200 "$selected_disk" # Linux swap
	sgdisk -n 3::+"$BPOOL_PARTITION_SIZE"        -t 3:BF01 "$selected_disk" # Mac ZFS (bpool)
	sgdisk -n 4::+"$TEMPORARY_VOLUME_SIZE"       -t 4:BF01 "$selected_disk" # Mac ZFS (rpool)
	sgdisk -n 5::                                -t 5:8300 "$selected_disk" # Linux File System

	# The partition symlinks are not immediately created, so we wait.
	#
	# There is still a hard to reproduce issue where `zpool create rpool` fails with:
	#
	#   cannot resolve path '/dev/disk/by-id/<disk_id>-part2'
	#
	# It's a race condition (waiting more solves the problem), but it's not clear which exact event
	# to wait on.
	# There's no relation to the missing symlinks - the issue also happened for partitions that
	# didn't need a `sleep`.
	#
	# Using `partprobe` doesn't solve the problem.
	#
	# Replacing the `-L` test with `-e` is a potential solution, but couldn't check on the
	# destination files, due to the nondeterministic nature of the problem.
	#
	# Current attempt: `udevadm`, which should be the cleanest approach.
	#
	udevadm settle --timeout "$c_udevadm_settle_timeout" || true

	# for disk in "${selected_disk[@]}"; do
	#   part_indexes=(1 2 3)
	#
	#   for part_i in "${part_indexes[@]}"; do
	#     while [[ ! -L "${disk}-part${part_i}" ]]; do sleep 0.25; done
	#   done
	# done

	mkfs.fat -F 32 -n esp "${selected_disk}-part1"  # EFI System Partition (FAT32)

	v_temp_volume_device=$(readlink -f "${selected_disk}-part5")
}

function install_operating_system {
  print_step_info_header install_operating_system

  local dialog_message='The Ubuntu GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Something Else` -> `Continue`
- select `'"$v_temp_volume_device"'` -> `Change`
  - set `Use as:` to `Ext4`
  - check `Format the partition:`
  - set `Mount point` to `/` -> `OK` -> `Continue`
- `Install Now` -> `Continue`
- at the end, choose `Continue Testing`
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  # The display is restricted only to the owner (`user`), so we need to allow any user to access
  # it.
  #
  sudo -u "$SUDO_USER" env DISPLAY=:0 xhost +

  DISPLAY=:0 ubiquity --no-bootloader

  swapoff -a

  # /target is not always unmounted; the reason is unclear. A possibility is that if there is an
  # active swapfile under `/target` and ubiquity fails to unmount /target, it fails silently,
  # leaving `/target` mounted.
  # For this reason, if it's not mounted, we remount it.
  #
  # Note that we assume that the user created only one partition on the temp volume, as expected.
  #
  if ! mountpoint -q "$c_installed_os_data_mount_dir"; then
    mount "$v_temp_volume_device" "$c_installed_os_data_mount_dir"
  fi

  rm -f "$c_installed_os_data_mount_dir/swapfile"
}

function install_operating_system_UbuntuServer {
  print_step_info_header install_operating_system_UbuntuServer

  # O/S Installation
  #
  # Subiquity is designed to prevent the user from opening a terminal, which is (to say the least)
  # incongruent with the audience.

  local dialog_message='Ubuntu Server installer (Subiquity) を実行してください

Alt + F1 を押して元の端末に戻り，設定を進めてください

Subiquity をアップデートするか問われたなら，アップデートしてください

パーティションの設定では:

- `Custom storage layout` -> `Done` を選択
- `'"$v_temp_volume_device"'` -> `Edit` を選択
  - `Format:` を `ext4` にします (mountpoint は自動で選択されます)
  - `Save` を押します
- `Done` -> `Continue` を押します (警告は無視してください)
- インストールを終わらせます (最後に実行されるアップデートも済ませてください)
- Alt + F2 を押してこの端末に戻り continue を押します

いまは Enter を押して continue しないでください!

この画面を見るためにいつでも端末を行き来できます
'

  whiptail --msgbox "$dialog_message" 30 100

  swapoff -a

  # See note in install_operating_system(). It's not clear whether this is required on Ubuntu
  # Server, but it's better not to take risks.
  #
  if ! mountpoint -q "$c_installed_os_data_mount_dir"; then
    mount "${v_temp_volume_device}p2" "$c_installed_os_data_mount_dir"
  fi

  rm -f "$c_installed_os_data_mount_dir"/swap.img
}

function create_pools {
	echo "function create_pools begins"
	echo "\$selected_disk is $selected_disk"

	# POOL OPTIONS #######################

	local rpool_disks_partitions="${selected_disk}-part4"
	local bpool_disks_partitions="${selected_disk}-part3"

	# POOLS CREATION #####################

	# See https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS for the details.
	#
	# `-R` creates an "Alternate Root Point", which is lost on unmount; it's just a convenience for a temporary mountpoint;
	# `-f` force overwrite partitions is existing - in some cases, even after wipefs, a filesystem is mistakenly recognized
	# `-O` set filesystem properties on a pool (pools and filesystems are distincted entities, however, プールは標準でひとつのファイルシステムを含む).
	#
	# Stdin is ignored if the encryption is not set (and set via prompt).
	#
	# shellcheck disable=SC2086 # quoting $v_pools_raid_type; barring invalid user input, the values are guaranteed not to
	# need quoting.

	echo "zpool create begins"

	# rpool をつくってから bpool をつくる
	# 逆だとマウントできなくなる

	echo "\$v_rpool_tweaks is $v_rpool_tweaks"
	echo "\$c_zfs_mount_dir is $c_zfs_mount_dir"
	echo "\$rpool_name is $rpool_name"
	echo "\$rpool_disks_partition is $rpool_disks_partition"
	zpool create -f ${v_rpool_tweaks} \
			-O mountpoint=/ -R "$c_zfs_mount_dir" \
			"$rpool_name" "${rpool_disks_partition}"  # rpool

	echo "\$v_bpool_tweaks is $v_bpool_tweaks"
	echo "\$c_zfs_mount_dir is $c_zfs_mount_dir"
	echo "\$bpool_name is $bpool_name"
	echo "\$bpool_disks_partition is $bpool_disks_partition"
	# `-d` disable all the pool features (not used here);
	#
	# shellcheck disable=SC2086 # see above
	zpool create -f ${v_bpool_tweaks} \
			-O mountpoint=/boot -R "$c_zfs_mount_dir" \
			"$bpool_name" "${bpool_disks_partition}"  # bpool

	echo "zpool create ends"
	echo "function create_pools ends"
}

function create_zfs_partitions {
	echo "create_zfs_partitions begins"

	zfs create -o mountpoint=/home           ${rpool_name}/home
	zfs create -o mountpoint=/opt            ${rpool_name}/opt
	zfs create -o mountpoint=/root           ${rpool_name}/root
	zfs create -o mountpoint=/snap           ${rpool_name}/snap
	zfs create -o mountpoint=/srv            ${rpool_name}/srv
	zfs create -o mountpoint=/tmp            ${rpool_name}/tmp
	zfs create -o mountpoint=/usr            ${rpool_name}/usr
	zfs create -o mountpoint=/var            ${rpool_name}/var
	zfs create -o mountpoint=/var/lib        ${rpool_name}/var/lib
	zfs create -o mountpoint=/var/lib/docker ${rpool_name}/var/lib/docker

	echo "create_zfs_partitions ends"
}

function sync_os_temp_installation_dir_to_rpool {
  print_step_info_header sync_os_temp_installation_dir_to_rpool

  # On Ubuntu Server, `/boot/efi` and `/cdrom` (!!!) are mounted, but they're not needed.
  #
  local mount_dir_submounts
  mount_dir_submounts=$(mount | MOUNT_DIR="${c_installed_os_data_mount_dir%/}" perl -lane 'print $F[2] if $F[2] =~ /$ENV{MOUNT_DIR}\//')

  for mount_dir in $mount_dir_submounts; do
    umount "$mount_dir"
  done

  # Extended attributes are not used on a standard Ubuntu installation, however, this needs to be generic.
  # There isn't an exact way to filter out filenames in the rsync output, so we just use a good enough heuristic.
  # ❤️ Perl ❤️
  #
  # `/run` is not needed (with an exception), and in Ubuntu Server it's actually a nuisance, since
  # some files vanish while syncing. Debian is well-behaved, and `/run` is empty.
  #
  rsync -avX --exclude=/run --info=progress2 --no-inc-recursive --human-readable "$c_installed_os_data_mount_dir/" "$c_zfs_mount_dir" |
    perl -lane 'BEGIN { $/ = "\r"; $|++ } $F[1] =~ /(\d+)%$/ && print $1' |
    whiptail --gauge "Syncing the installed O/S to the root pool FS..." 30 100 0

  mkdir "$c_zfs_mount_dir/run"

  # Required destination of symlink `/etc/resolv.conf`, present in Ubuntu systems (not Debian).
  #
  if [[ -d $c_installed_os_data_mount_dir/run/systemd/resolve ]]; then
    rsync -av --relative "$c_installed_os_data_mount_dir/run/./systemd/resolve" "$c_zfs_mount_dir/run"
  fi

  umount "$c_installed_os_data_mount_dir"
}

function remove_temp_partition_and_expand_rpool {
	print_step_info_header remove_temp_partition_and_expand_rpool

	parted -s "$selected_disk" rm 5
	parted -s "$selected_disk" unit s resizepart 4 -- "100%"
	zpool online -e "$rpool_name" "${selected_disk}-part4"
}

function prepare_jail {
	print_step_info_header prepare_jail

	for virtual_fs_dir in proc sys dev; do
		mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
	done

	chroot_execute 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
}

# See install_host_packages() for some comments.
#
function install_jail_zfs_packages {
	print_step_info_header install_jail_zfs_packages

	# Oddly, on a 20.04 Ubuntu Desktop live session, the zfs tools are installed, but they are not
	# associated to a package:
	#
	# - `dpkg -S $(which zpool)` -> nothing
	# - `aptitude search ~izfs | awk '{print $2}' | xargs echo` -> libzfs2linux zfs-initramfs zfs-zed zfsutils-linux
	#
	# The packages are not installed by default, so we install them.
	#
	chroot_execute "apt install -y libzfs2linux zfs-initramfs zfs-zed zfsutils-linux"

	chroot_execute "apt install -y grub-efi-amd64-signed shim-signed"
}

function install_and_configure_bootloader {
  print_step_info_header install_and_configure_bootloader

  chroot_execute "echo PARTUUID=$(blkid -s PARTUUID -o value "${selected_disk}-part1") /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 > /etc/fstab"

  chroot_execute "mkdir -p /boot/efi"
  chroot_execute "mount /boot/efi"

  chroot_execute "grub-install"

  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX=\")/\${1}root=ZFS=$rpool_name /'    /etc/default/grub"

  # Silence warning during the grub probe (source: https://git.io/JenXF).
  #
  chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'                                    >> /etc/default/grub"

  # Simplify debugging, but most importantly, disable the boot graphical interface: text mode is
  # required for the passphrase to be asked, otherwise, the boot stops with a confusing error
  # "filesystem [...] can't be mounted: Permission Denied".
  #
  chroot_execute "perl -i -pe 's/(GRUB_TIMEOUT_STYLE=hidden)/#\$1/'                        /etc/default/grub"
  chroot_execute "perl -i -pe 's/^(GRUB_HIDDEN_.*)/#\$1/'                                  /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_TIMEOUT=)0/\${1}5/'                                 /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX_DEFAULT=.*)quiet/\$1/'                /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX_DEFAULT=.*)splash/\$1/'               /etc/default/grub"
  chroot_execute "perl -i -pe 's/#(GRUB_TERMINAL=console)/\$1/'                            /etc/default/grub"
  chroot_execute 'echo "GRUB_RECORDFAIL_TIMEOUT=5"                                      >> /etc/default/grub'

  # A gist on GitHub (https://git.io/JenXF) manipulates `/etc/grub.d/10_linux` in order to allow
  # GRUB support encrypted ZFS partitions. This hasn't been a requirement in all the tests
  # performed on 18.04, but it's better to keep this reference just in case.

  chroot_execute "update-grub"  # grub-mkconfig -o /boot/grub/grub.cfg と同じ
}

function configure_boot_pool_import {
	print_step_info_header configure_boot_pool_import

	chroot_execute "cat > /etc/systemd/system/zfs-import-${bpool_name}.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '[ -f /etc/zfs/zpool.cache ] && mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache || true'
ExecStart=/sbin/zpool import -N -o cachefile=none ${bpool_name}
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

  chroot_execute "systemctl enable zfs-import-${bpool_name}.service"

  chroot_execute "zfs set mountpoint=legacy ${bpool_name}"
  chroot_execute "echo ${bpool_name} /boot zfs nodev,relatime,x-systemd.requires=zfs-import-${bpool_name}.service 0 0 >> /etc/fstab"
}

# We don't care about synchronizing with the `fstrim` service for two reasons:
#
# - we assume that there are no other (significantly) large filesystems;
# - trimming is fast (takes minutes on a 1 TB disk).
#
# The code is a straight copy of the `fstrim` service.
#
function configure_pools_trimming {
  print_step_info_header configure_pools_trimming

  chroot_execute "cat > /lib/systemd/system/zfs-trim.service << UNIT
[Unit]
Description=Discard unused ZFS blocks
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=/sbin/zpool trim $bpool_name
ExecStart=/sbin/zpool trim $rpool_name
UNIT"

  chroot_execute "  cat > /lib/systemd/system/zfs-trim.timer << TIMER
[Unit]
Description=Discard unused ZFS blocks once a week
ConditionVirtualization=!container

[Timer]
OnCalendar=weekly
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER"

  chroot_execute "systemctl daemon-reload"
  chroot_execute "systemctl enable zfs-trim.timer"
}

function configure_remaining_settings {
	print_step_info_header configure_remaining_settings

	local block_device_basename=$(basename $(readlink -f $selected_disk))

	[[ $swap_size -gt 0 ]] && chroot_execute "echo /dev/${block_device_basename}2 swap swap defaults 0 0 >> /etc/fstab" || true
	chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"  # ハイバネーション無
}

function prepare_for_system_exit {
  print_step_info_header prepare_for_system_exit

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  # In one case, a second unmount was required. In this contenxt, bind mounts are not safe, so,
  # expecting unclean behaviors, we perform a second unmount if the mounts are still present.
  #
  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  zpool export -a
}

function display_exit_banner {
  print_step_info_header display_exit_banner

	local dialog_message="システムの準備ができました

システムを再起動してください ---- Enjoy your ZFS system :-)"

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi
}

# サブコマンド
if [[ " $1" = " main" ]]; then
	main
elif [[ " $1" = " stage1" ]]; then
	stage1
elif [[ " $1" = " stage2" ]]; then
	stage2
fi

# 未定義のサブコマンドなら help を表示して終了
display_help_and_exit

# /boot/efi/EFI/ubuntu/grub.cfg の例
# GRUB のプロンプトで grub> ls -l とすると UUID を確認できる
# GPT の GUID ではないので注意
#
# search --fs-uuid 0123456789abcdef --set bpool
# configfile ($bpool)/@/grub/grub.cfg
