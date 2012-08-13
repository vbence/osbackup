#!/bin/sh

# saving partition table
sfdisk -d /dev/sda > partitions

# saving block-device IDs
blkid > blkid

# back-up LVM configs
vgcfgbackup --file lvm

# save RAID (md) info
mdadm -Es > md

# copy RAID array parameters
cp /proc/mdstat mdstat

# copy dm_crypt parameters
cp /etc/crypttab crypttab

# copy fstab for initial filesystems
cp /etc/fstab fstab

# save LUKS info
touch luks
rm luks
for file in /dev/mapper/*
do
    info=`./lukstool shortinfo $file 2>/dev/null`
    if [ "$info" !=  "" ]
    then
        echo $file $info >>luks
    fi
done
