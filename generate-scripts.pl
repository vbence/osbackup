#!/usr/bin/perl -w

use strict;
use warnings;

use IO::File;
use File::Path;
use File::Copy;
use Data::Dumper;

my $SCRIPTS_DIR = "restore";
my $SYS_ROOT_DIR = "/tmp/restore-root";

sub write_file($$) {
    my($name, $buffer) = @_;

    my $fh = IO::File->new();
    $fh->open($name, "w");
    $fh->write($buffer);
    $fh->close();
}

sub append_file($$) {
    my($name, $buffer) = @_;

    my $fh = IO::File->new();
    $fh->open($name, "a");
    $fh->write($buffer);
    $fh->close();
}

# Reading block IDs for devices
sub blkid_read () {
    my @devs = ();
    my $fh = IO::File->new();
    $fh->open("metadata/blkid", "r");
    while (my $line = $fh->getline()) {

        my $dev = {};
        if ($line =~ /^(\/dev\/[^:]+)/) {
            $dev->{"path"} = $1;
        };

        if ($line =~ /UUID="([^\"]+)"/) {
            $dev->{"uuid"} = $1;
        };

        if ($line =~ /LABEL="([^\"]+)"/) {
            $dev->{"label"} = $1;
        };

        if ($line =~ /TYPE="([^\"]+)"/) {
            $dev->{"type"} = $1;
        };

        push @devs, $dev;

    }
    $fh->close;

    return @devs;
}

sub blkid_info_by_id (\@$){
    my($devs, $id) = @_;

    my $dev;
    foreach $dev (@{$devs}) {
        if ($dev->{"uuid"} eq $id) {
            return $dev;
        }
    }
}

sub blkid_info_by_path (\@$){
    my($devs, $path) = @_;

    my $dev;
    foreach $dev (@{$devs}) {
        if ($dev->{"path"} eq $path) {
            return $dev;
        }
    }
}

# Reading partitions
sub read_partitions () {
    my @partitions = ();
    my $part = {};
    my $fh = IO::File->new();
    $fh->open("metadata/partitions", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^# partition table of (\/dev\/([a-z0-9]+))/) {
            $part = {};
            push @partitions, $part;
            $part->{"name"} = "PARTITION/" . $2;
            $part->{"requires"} = [$1];
            $part->{"provides"} = [];

            # write restore script
            my $path = $SCRIPTS_DIR . "/" . $part->{"name"};
            mkpath($path);
            write_file($path . "/script", "#!/bin/sh\nsfdisk " . $1 . " < sfdisk_dump");
            chmod 0755, $path . "/script";
            write_file($path . "/sfdisk_dump", "");

        };

        if ($line =~ /^(\/dev\/[a-z0-9]+) /) {
            push(@{$part->{"provides"}}, $1);
        }

        # write line to dump file (segmenting central dump file)
        append_file($SCRIPTS_DIR . "/" . $part->{"name"} . "/sfdisk_dump",  $line);
        #$part->{"text"} .= $line;

    }
    $fh->close;

    foreach $part (@partitions) {
        my $path = $SCRIPTS_DIR . "/" . $part->{"name"};
    }

    return @partitions;
}

# Reading RAID metadata
sub read_raid (\@) {
    my($devs) = @_;

    my @arrays = ();
    my $array = {};
    my $fh = IO::File->new();
    $fh->open("metadata/mdstat", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^(md([0-9]+)) : [^ ]+ (raid[0-9]+) (.*)/) {
            $array = {};
            push(@arrays, $array);
            $array->{"name"} = "RAID/" . $1;
            $array->{"type"} = $3;
            $array->{"provides"} = ["/dev/" . $1, "/dev/md/" . $2];
            $array->{"requires"} = [];
            my $members = $4;
            while ($members =~ /([a-z0-9]+)\[[0-9]+\]/g) {
                push @{$array->{"requires"}}, "/dev/" . $1;
            }

            # write restore script
            my $path = $SCRIPTS_DIR . "/" . $array->{"name"};
            mkpath($path);
            my $script = "#!/bin/sh\nmdadm --create /dev/" . $1  . " --metadata=1.2 --level=" . $3 . " --uuid=" . blkid_info_by_path(@$devs, "/dev/" . $1)->{"uuid"} . " --raid-devices=" . scalar(@{$array->{"requires"}}) . " \\\n";
            my $member;
            foreach $member (@{$array->{"requires"}}) {
                $script .= "`[ -e " . $member . " ] && echo " . $member . " || echo missing` \\\n";
            }
            write_file($path . "/script", $script);
            chmod 0755, $path . "/script";

        };
    }
    $fh->close;

    return @arrays;
}

# Reading LVM metadata
sub read_lvm () {

    use constant IN_VOLUME => 1;
    use constant IN_PHYSICAL => 2;
    use constant IN_LOGICAL => 3;

    my @volumes = ();
    my $volume = {};
    my $status = IN_VOLUME;
    my $volname;

    my $fh = IO::File->new();
    $fh->open("metadata/lvm", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^\tphysical_volumes \{/) {
            $status = IN_PHYSICAL;
        } elsif ($line =~ /^\tlogical_volumes \{/) {
            $status = IN_LOGICAL;
        };

        # volume starting
        if ($line =~ /^([^\t ]+) \{/) {
            $volume = {};
            push @volumes, $volume;
            $volname = $1;
            $volume->{"name"} = "LVM/" . $volname;
            $volume->{"requires"} = [];
            $volume->{"provides"} = [];

            my $path = $SCRIPTS_DIR . "/" . $volume->{"name"};
            mkpath($path);
            copy("metadata/lvm", $path . "/lvm_backup");
            write_file($path . "/script", "#!/bin/sh\n./physical\nvgcfgrestore -f lvm_backup -v " . $volname);
            chmod(0755, $path . "/script");
            write_file($path . "/physical", "#!/bin/sh\n");
            chmod(0755, $path . "/physical");
        };

        if ($status == IN_PHYSICAL) {

            # device (for physical volume)
            if ($line =~ /device = "([^"]+)"/) {
                push @{$volume->{"requires"}}, $1;

                my $path = $SCRIPTS_DIR . "/" . $volume->{"name"};
                append_file($path . "/physical", "pvcreate --restorefile lvm_backup " . $1 . "\n");
            };

        } elsif ($status == IN_LOGICAL) {

            # (logical) volume header
            if ($line =~ /^\t\t([^\t ]+) \{/) {
                push @{$volume->{"provides"}}, "/dev/" . $volname . "/" . $1;
                push @{$volume->{"provides"}}, "/dev/mapper/" . $volname . "-" . $1;
            };
        };
    }
    $fh->close;

    return @volumes;
}

# Reading crypttab
sub read_luks (\@) {
    my ($devs) = @_;

    my @objects = ();
    my $part = {};
    my $fh = IO::File->new();
    $fh->open("metadata/luks", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^\/dev\/mapper\/([^ "]+|"[^"]+") ([^ "]+|"[^"]+") ([^ "]+|"[^"]+") ([^ "]+|"[^"]+")\n/) {

            my $name = $1;
            my $dev = "/dev/mapper/" . $1;
            my $cypher  = $2;
            my $bits = $ 3;
            my $uuid = $ 4;

            # create and store new object
            $part = {};
            push @objects, $part;
            
            # store name and device name
            $part->{"name"} = "LUKS/" . $name . "_crypt";
            $part->{"provides"} = ["/dev/mapper/" . $name . "_crypt"];
            $part->{"requires"} = [$dev];

            my $path = $SCRIPTS_DIR . "/" . $part->{"name"};
            mkpath($path);
            write_file($path . "/script", "#!/bin/sh\ncryptsetup luksformat --cipher $cypher --key-size $bits $dev\nlukstool setuuid $dev \"$uuid\"");
            chmod(0755, $path . "/script");
            copy("tools/lukstool", $path);
            chmod(0755, $path . "/lukstool");
        };

    }
    $fh->close;

    return @objects;
}

# Reading crypttab
sub read_crypttab (\@) {
    my ($devs) = @_;

    my @objects = ();
    my $part = {};
    my $fh = IO::File->new();
    $fh->open("metadata/crypttab", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^(.+?)[ \t]+(.+?)[ \t]+(.+?)[ \t]+(.+?)[ \t\n]/) {

            my $name = $1;
            my $dev = $2;
            my $keyfile = $3;
            my $params = $4;

            if ($params =~ /(swap|tmp)/) {

                # create and store new object
                $part = {};
                push @objects, $part;
                
                # store name and device name
                $part->{"name"} = "CRYPT/" . $name;
                $part->{"provides"} = ["/dev/mapper/" . $name];
                $part->{"requires"} = [$dev];

                my $path = $SCRIPTS_DIR . "/" . $part->{"name"};
                mkpath($path);
                write_file($path . "/script", "#!/bin/sh\n# dummy script");
                chmod(0755, $path . "/script");
            }
        };

    }
    $fh->close;

    return @objects;
}

sub read_fstab (\@) {
    my ($devs) = @_;

    my @objects = ();
    my $part = {};
    my $fh = IO::File->new();
    $fh->open("metadata/fstab", "r");
    while (my $line = $fh->getline()) {

        if ($line =~ /^(\/dev\/.+?|UUID=.+?)[ \t]+(.+?)[ \t]+(ext2|ext3|ext4|msdos|vfat)[ \t]+/) {

            # create and store new object
            $part = {};
            push @objects, $part;

            my $dev = $1;
            my $mount = $2;
            my $type = $3;
            my $uuid;

            if ($dev =~ /^UUID=(.+)/) {
                $uuid = $1;
                $dev = blkid_info_by_id(@$devs, $1)->{"path"};
            } else {
                my $info = blkid_info_by_path(@$devs, $dev);
                if ($info) {
                    $uuid = $info->{"uuid"};
                }
            }

            my $name = $dev;
            $name =~ s/[^a-z0-9.-]/_/ig;
            $name = "FS/" . $name;
            $part->{"name"} = $name;
            $part->{"provides"} = [$mount];
            $part->{"requires"} = [$dev];
            if ($mount ne "/") {
                push(@{$part->{"requires"}}, "/");
            }


            my $script = "#!/bin/sh\nmkfs.$type $dev";
            if ($uuid) {
                $script .= " -U $uuid";
            }
            $script .= "\n";

            my $mountpoint = $SYS_ROOT_DIR . $mount;
            $script .= "mkdir -p $mountpoint\n";
            $script .= "mount $dev $mountpoint\n";

            my $path = $SCRIPTS_DIR . "/" . $part->{"name"};
            mkpath($path);
            write_file($path . "/script", $script);
            chmod(0755, $path . "/script");
        }
    }

    $fh->close;

    return @objects;
}

#
# Reading saved metadata structures
#

# device id (and type) info
my @blkid = blkid_read();

# objects representing blovk devices
my @blockdevs;
push @blockdevs, read_raid(@blkid);
push @blockdevs, read_lvm();
push @blockdevs, read_luks(@blkid);
push @blockdevs, read_crypttab(@blkid);
push @blockdevs, read_fstab(@blkid);
push @blockdevs, read_partitions();
#print(Dumper(@blockdevs));


#
# Mark the trivial requirements as "present"
#
my $present = {};

# mark all requirements
foreach my $blockdev (@blockdevs) {
    foreach my $dependance (@{$blockdev->{"requires"}}) {
        $present->{$dependance} = 1;
    }
}

# remove the ones which can be provided 
foreach my $blockdev (@blockdevs) {
    foreach my $provided (@{$blockdev->{"provides"}}) {
        delete $present->{$provided};
    }
}

#
# Generate master script with the correct order
#

# generate order
my $order = ();
my $change = 1;
while ($change) {
    $change = 0;

    for (my $i=0; $i<scalar(@blockdevs); $i++) {

        my $blockdev = $blockdevs[$i];

        my $go = 1;
        foreach my $dependance (@{$blockdev->{"requires"}}) {
            $go = $go && ($present->{$dependance});
            if (! $go) {
                last;
            }
        }

        if ($go) {
            push(@$order, $blockdev);
            foreach my $provided (@{$blockdev->{"provides"}}) {
                $present->{$provided} = 1;
            }
            splice(@blockdevs, $i, 1);
            $change = 1;
            $i--;
            last;
        }
    }
}

# write script
my $script = "#!/bin/sh\n\nWORK_DIR=`pwd`\n\n";

$script .= "if [ \$# = 0 ]\nthen\n\techo Usage: $0 \\<path/to/backup.tgz\\>\nexit\nfi\n\n";
$script .= "if [ `id -u` != 0 ]\nthen\n\techo WARNING: You probably want to run this script as root.\nfi\n\n";
foreach my $item (@$order) {
    print($item->{"name"} . "\n");
    $script .= "cd " . $item->{"name"} . "\n./script\ncd \$WORK_DIR\n\n";
}

$script .= "cd $SYS_ROOT_DIR\ntar -xvzf --numeric-owner \$1\nmkdir proc sys tmp\ncd \$WORK_DIR\n\n";
$script .= "mount --bind /dev $SYS_ROOT_DIR/dev\nchroot $SYS_ROOT_DIR grub-install\n";

write_file($SCRIPTS_DIR . "/restore", $script);
chmod(0755, $SCRIPTS_DIR . "/restore");
