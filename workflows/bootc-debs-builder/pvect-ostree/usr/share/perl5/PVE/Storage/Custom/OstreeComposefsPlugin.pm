package PVE::Storage::Custom::OstreeComposefsPlugin;

# ---------------------------------------------------------------------------
# EXPERIMENTAL — not enabled by default. See README.plugin.md.
#
# A thin PVE storage plugin whose only job is to (re)establish the composefs
# rootfs of a pvect-ostree-managed container at the moment PVE activates the
# volume — i.e. right before it stages the rootfs at container start. All of the
# real work (deploy, id-mapped mount.composefs, writable /etc + /var) is done by
# the /usr/sbin/pvect-ostree CLI, which is the validated code path; this plugin
# just calls into it so container start from the Web UI triggers the mount
# natively, without a hookscript.
#
# The plugin deliberately does NOT reimplement allocation: containers are still
# created with `pvect-ostree create`, which allocates a normal dir subvol and
# records the mapping. This module is opt-in and self-contained so that, if it
# misbehaves, it cannot affect the built-in storage types.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use File::Path ();
use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

use constant PVECT => '/usr/sbin/pvect-ostree';

sub api {
    # Keep in range of the storage API this was written against.
    return 15;
}

sub type {
    return 'pvect-ostree';
}

sub plugindata {
    return {
        content => [{ rootdir => 1 }, { rootdir => 1 }],
        format  => [{ subvol => 1 }, 'subvol'],
    };
}

sub properties {
    return {
        'pvect-sysroot' => {
            description => "ostree sysroot holding the composefs deployments.",
            type        => 'string',
            default     => '/var/lib/pvect-ostree/sysroot',
        },
    };
}

sub options {
    return {
        nodes          => { optional => 1 },
        disable        => { optional => 1 },
        content        => { optional => 1 },
        'pvect-sysroot' => { optional => 1 },
    };
}

# volname is 'subvol-<vmid>-disk-0.subvol'; pull the vmid out of it.
sub parse_volname {
    my ($class, $volname) = @_;
    if ($volname =~ m/^subvol-(\d+)-disk-\d+/) {
        return ('rootdir', $volname, $1, undef, undef, undef, 'subvol');
    }
    die "unable to parse pvect-ostree volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    die "snapshots are not supported by pvect-ostree\n" if defined($snapname);
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    my $path = "/var/lib/vz/images/$vmid/$volname";
    return wantarray ? ($path, $vmid, 'rootdir') : $path;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    return $class->filesystem_path($scfg, $volname, $snapname);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    # (total, avail, used, active) — report the backing sysroot filesystem.
    my $sysroot = $scfg->{'pvect-sysroot'} // '/var/lib/pvect-ostree/sysroot';
    my $st = eval { PVE::Tools::df($sysroot) };
    return (0, 0, 0, 1) if !$st;
    return ($st->{total}, $st->{avail}, $st->{used}, 1);
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    die "snapshots are not supported by pvect-ostree\n" if defined($snapname);
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    run_command([PVECT, 'mount', $vmid]);
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    # Best-effort: leave the mount if the container is still running.
    eval { run_command([PVECT, 'umount', $vmid]) };
    return 1;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return [];
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    return 0;
}

sub create_base { die "create_base is not supported by pvect-ostree\n"; }
sub clone_image { die "clone_image is not supported by pvect-ostree\n"; }
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "unsupported format '$fmt'\n" if defined($fmt) && $fmt ne 'subvol';
    $name //= "subvol-$vmid-disk-0.subvol";
    my $dir = "/var/lib/vz/images/$vmid";
    File::Path::make_path("$dir/$name");
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    return undef;
}

1;
