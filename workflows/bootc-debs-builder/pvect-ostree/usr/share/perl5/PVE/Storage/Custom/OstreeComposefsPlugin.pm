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
        content => [{ rootdir => 1, vztmpl => 1 }, { rootdir => 1, vztmpl => 1 }],
        format  => [{ subvol => 1 }, 'subvol'],
    };
}

# Seed templates published by `pvect-ostree publish` live under the sysroot.
my $TEMPLATES_SUBDIR = 'vztmpl';

sub properties {
    return {
        # 'path' is inherited from PVE::Storage::Plugin (no redefinition:
        # SectionConfig rejects duplicate properties). It must be set on the
        # storage (see seed) so alloc_disk takes the subvol (no mkfs) branch
        # for `--rootfs <storeid>:0`.
        'pvect-sysroot' => {
            description => "ostree sysroot holding the composefs deployments.",
            type        => 'string',
            default     => '/var/lib/pvect-ostree/sysroot',
        },
    };
}

sub options {
    return {
        nodes           => { optional => 1 },
        disable         => { optional => 1 },
        content         => { optional => 1 },
        path            => { optional => 1 },
        'pvect-sysroot' => { optional => 1 },
    };
}

# volname is 'subvol-<vmid>-disk-0.subvol' or 'vztmpl/<stack>.tar.gz'.
sub parse_volname {
    my ($class, $volname) = @_;
    if ($volname =~ m|^vztmpl/([^/]+\.tar\.gz)$|) {
        return ('vztmpl', $volname, undef, undef, undef, undef, 'tar.gz');
    }
    if ($volname =~ m/^subvol-(\d+)-disk-\d+/) {
        return ('rootdir', $volname, $1, undef, undef, undef, 'subvol');
    }
    die "unable to parse pvect-ostree volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    die "snapshots are not supported by pvect-ostree\n" if defined($snapname);
    my $sysroot = $scfg->{'pvect-sysroot'} // '/var/lib/pvect-ostree/sysroot';
    if ($volname =~ m|^vztmpl/(.+)$|) {
        my $path = "$sysroot/$TEMPLATES_SUBDIR/$1";
        return wantarray ? ($path, undef, 'vztmpl') : $path;
    }
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    my $path = ($scfg->{path} // '/var/lib/pvect-ostree/sysroot/volumes')
        . "/$vmid/$volname";
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
    my @v = $class->parse_volname($volname);
    return 1 if $v[0] eq 'vztmpl';
    my $vmid = $v[2];
    # A CT created from a published seed template is only registered at its
    # first activation: pct create activates the (empty) volume before the
    # template extraction, so an unregistered volume with no seed is normal
    # mid-create.
    my $managed = eval { run_command([PVECT, 'mount', $vmid]); 1 } // 0;
    return 1 if $managed;
    my $subvol = _pvect_out('subvol-path', $vmid);
    $subvol //= '';
    $subvol =~ s/\s+$//;
    if (-f "$subvol/pvect-ostree/payload.env") {
        run_command([PVECT, 'adopt', $vmid]);
    }
    # else: mid-create (seed not extracted yet) — nothing to mount, and the
    # next activation (start) adopts it.
    return 1;
}

#######################################
# Run a pvect-ostree subcommand printing a single line and return that line.
# Arguments:
#   @_ - the pvect-ostree subcommand and its arguments
# Outputs:
#   Nothing (the captured line is the return value).
# Returns:
#   The stripped stdout line, or undef when the command failed.
#######################################
sub _pvect_out {
    my @cmd = (PVECT, @_);
    my $out;
    eval {
        run_command(\@cmd, outfunc => sub { $out .= $_[0] // '' });
    };
    return $out;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    my @v = $class->parse_volname($volname);
    return 1 if $v[0] eq 'vztmpl';
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    # Best-effort: leave the mount if the container is still running.
    eval { run_command([PVECT, 'umount', $vmid]) };
    return 1;
}

# List the published seed templates in the standard vztmpl shape, so `pvesm
# list <storeid>` and the GUI template pickers work unchanged; this storage has
# no configurable path, so the base-class subdir walk cannot apply.
sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    my $sysroot = $scfg->{'pvect-sysroot'} // '/var/lib/pvect-ostree/sysroot';

    if (!grep { $_ eq 'vztmpl' } @$content_types) {
        return $class->SUPER::list_volumes($storeid, $scfg, $vmid, $content_types);
    }

    my $res = [];
    my $dir = "$sysroot/$TEMPLATES_SUBDIR";
    if (opendir(my $dh, $dir)) {
        while (defined(my $fn = readdir($dh))) {
            next if $fn !~ m{^([^/]+\.tar\.gz)$};
            my $file = "$dir/$fn";
            next if !-f $file;
            push @$res, {
                volid  => "$storeid:vztmpl/$fn",
                format => 'tar.gz',
                size   => (-s $file),
            };
        }
        closedir($dh);
    }
    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return [];
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    if ($volname =~ m|^vztmpl/|) {
        my $path = $class->filesystem_path($scfg, $volname);
        return (-f $path) ? (-s $path) : 0;
    }
    return 0;
}

sub create_base { die "create_base is not supported by pvect-ostree\n"; }
sub clone_image { die "clone_image is not supported by pvect-ostree\n"; }
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    # pct create asks for 'raw' (size-given) or 'subvol' (--rootfs <sid>:0);
    # both map to the same empty seed directory — the composefs view is
    # mounted over it at activation, the size is nominal.
    die "unsupported format '$fmt'\n"
        if defined($fmt) && $fmt ne 'subvol' && $fmt ne 'raw';
    $name //= "subvol-$vmid-disk-0.subvol";
    my $dir = ($scfg->{path} // '/var/lib/pvect-ostree/sysroot/volumes') . "/$vmid";
    # Allocation starts from an empty volume: a previous failed create leaves
    # seed content and PVE extracts templates with --skip-old-files, so stale
    # files would leak into the new container (wrong etc/os-release included).
    File::Path::remove_tree("$dir/$name");
    File::Path::make_path("$dir/$name");
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    # Delete like the dir storage does, so a destroyed vmid can be recreated;
    # only rootdir volumes in our own path are touched.
    my $vtype = eval { ($class->parse_volname($volname))[0] } // '';
    return undef if $vtype ne 'rootdir';
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    my $base = $scfg->{path} // '/var/lib/pvect-ostree/sysroot/volumes';
    File::Path::remove_tree("$base/$vmid") if $base;
    return undef;
}

1;
