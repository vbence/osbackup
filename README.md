OSBackup
========

The goal of *OSBackup* is to restore (or clone) your Linux-based system with minimal storage requirements. It works by capturing metadata of your block devices and compiling minimal scripts to re-create the same structure on the new disks.

It is available under GNU General Public License.

> **Note:** The current version is a working prototype. It is far from production usage. **Testers wanted.**

## Technologies

The following structures are scanned and restored (respecting any  dependency between them).

 * **Partition tables** of block devices (through *sfdisk*).
 * **Raid arrays** compatible with *mdadm*.
 * **Logical volumes** using *LVM*.
 * **Encrypted devices** using *dm_crypt* (the user will be prompted for the new passphrases).
 * **File systems**, as long as they are ext* or vfat.
 * **Grub** boot loader.

## Restore process

The ideal restore environment is a *live CD* with the same distribution the backed-up system is running.

The script will first scan for the binaries it will use (like *cryptsetup* or *mkfs.ext4*) and complain if something is not available. At this point you have to add the packages providing these commands (e.g. `apt-get install lvm2`).

If everything is available, the script will re-create all the structures, make all the file systems, mount them, extract the gzipped tarball with the files and re-install Grub in a chrooted environment.

Your system should be available after a reboot (at least in theory).

## Usage

You just have to run the `osbackup` shellscript. It will put everything you need under the *restore* folder (including a large *gzip* archive with all the files which were not explicitly excluded, like */tmp* and friends).

It worth mentioning that the script will keep the metadata files under the *metadata* directory, so if the automatic process fails to restore something you can do it manually using this information (like what UUID a file system should have).

Simply running the `restore` shell script in the *restore* directory should finish the process.

### Notes

 * You can add any additional directories to the exclude list using the `TAR_FLAGS` environment variabale, which will be appended to the tar command line. For example: `--exclude=/home` (because there are better tools to take care of often changing data).
 * If your backup archive (*root.tar.gz*) is located somewhere else than the restore script, you can add that filename as the first parameter after `restore`.

