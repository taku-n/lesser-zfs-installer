# lesser-zfs-installer

lesser-zfs-installer forked from [zfs-installer](https://github.com/saveriomiroddi/zfs-installer) is a shell script program that fully prepares ZFS on a system, and allows an effortless installation of Ubuntu operating systems using their standard installer.

lesser-zfs-installer makes a swap partition as a legacy partition and ZFS partitions of /home, /opt, /root, /snap, /srv, /tmp, /usr/local, /var, and /var/lib/docker.

lesser-zfs-installer can not treat multiple disks and RAID.

## Requirements and functionality

The program currently supports:

- Ubuntu Desktop 20.04 Live
- Ubuntu Server 20.04 Live

The ZFS version installed is 0.8, which supports native encryption and trimming (among the other improvements over 0.7). The required repositories are automatically added to the destination system.

EFI boot is required (any modern (2011+) system will do); legacy boot is not supported.

## Comparison with Ubuntu built-in installer

As of 20.04, Canonical makes available an experimental ZFS installer on Ubuntu Desktop.

The advantages of this project over the Ubuntu installer are:

1. it supports pools configuration;
2. it allows specifying the RAID type;
3. it allows customization of the disk partitions;
4. it supports additional features (e.g. encryption);
5. it supports many more operating systems;
6. it supports unattended installations, via custom scripts;
7. it installs a convenient trimming job for ZFS pools;
8. it's easy to extend.

The disadvantages are:

1. the Ubuntu installer has a more sophisticated filesystem layout - it separates base directories into different ZFS filesystems (this is planned to be implemented in the ZFS installer as well).

## Instructions

Start the live CD of a supported Linux distribution, then open a terminal and execute:

```sh
GET https://git.io/JfPVP | sudo bash
```

then follow the instructions; halfway through the procedure, the GUI installer of the O/S will be launched.

### Ubuntu Server

Ubuntu Server requires a slightly different execution procedure:

- when the installer welcome screen shows up, press `Alt + F2`,
- then type `curl -L https://git.io/JfPVP | sudo bash`.
- If you are using a ConoHa VPS, `curl -L https://git.io/JfjRA | sudo bash` instead.

then follow the instructions.

### After Installation (optional)

If you want to make a ZFS partition for your home directory, type these commands.

```
$ cd
$ pwd               # Check your home directory.

$ sudo -i           # To avoid creating ".sudo_as_admin_successful" when you execute zfs command.
# shopt -s dotglob  # To move dot files too.
# mkdir /tmp/temp
# mv /home/{your-username}/* /tmp/temp

# # These properties are inherited from their pool.
# # compression, devices, xattr, dnodesize, acltype, relatime
# zfs create -o mountpoint=/home/{your-username} rpool/home/{your-username}

# mv /tmp/temp/* /home/{your-username}
# chown {your-username}:{your-username} /home/{your-username}
# exit
$ exit              # To see the files moved.
```

## Demo

![Demo](/demo/demo.gif?raw=true)

### Unsupported systems/Issues

The Ubuntu Server alternate (non-live) version is not supported, as it's based on the Busybox environment, which lacks several tools used in the installer (apt, rsync...).

The installer itself can run over SSH (\[S\]Ubiquity of course needs to be still run in the desktop environment, unless a custom script is provided), however, GNU Screen sessions may break, due to the virtual filesystems rebinding/chrooting. This is not an issue with the ZFS installer; it's a necessary step of the destination configuration.

## Bug reporting/feature requests

This project is entirely oriented to community requests, as the target is to facilitate ZFS adoption.

Both for feature requests and bugs, [open a GitHub issue](https://github.com/taku-n/lesser-zfs-installer/issues/new).

For issues, also attach the content of the directory `/tmp/zfs-installer`. It doesn't contain any information aside what required for performing the installation; it can be trivially inspected, as it's a standard Bash debug output.

## Credits

The workflow of this program is based on the official ZFS wiki procedure, so, many thanks to the ZFS team.

Many thanks also to Gerard Beekmans for reaching out and giving useful feedback and help.

Thank you, [saveriomiroddi](https://saveriomiroddi.github.io).

[BS img]: https://travis-ci.org/saveriomiroddi/zfs-installer.svg?branch=master
