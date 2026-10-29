package PVE::Storage::Custom::QcowBindPlugin;

# ---------------------------------------------------------------------------
# PROTOTYPE — not enabled by default. See README.plugin.md and the wiki page
# "qcowbind-design.md".
#
# A PVE storage plugin for SHARED multi-LXC volumes backed by qcow2 images.
# The qcow2 IS the volume: it is the only format where a shrink really
# returns space (qemu-img convert/sparsify — a ZFS refquota never reclaims).
# The ZFS dataset underneath (e.g. SSD-600G/ia-ssd) is only the container:
# pool-level compression and snapshots still apply.
#
# Mount model (host-side, never inside a single CT):
#   qcow2 image -> qemu-nbd connect -> kernel FS mount -> one host mountpoint
#   -> bind-mounted (lxc.mount.entry) into N containers.
#
# Lifecycle via the standard PVE storage API, so everything is native UI,
# no CLI needed:
#   alloc_image   -> qemu-img create
#   free_image    -> refuse if attached, unmount, disconnect nbd, remove file
#   resize_volume -> grow: qemu-img resize; shrink: qemu-img convert to a
#                    sparse temp file + swap (the only path that returns blocks)
#   activate_volume / deactivate_volume -> nbd connect + FS mount / unmount
#
# Guards:
#   - refuse any activation while a KVM VM config references the volume
#     (qcow2 LXC-bind usage conflicts with qcow2-as-VM-disk usage);
#   - a JSON sidecar (<vol>.qbind.json) records nbd device, mountpoint and
#     bound CTs; it is cross-checked against the real system state at every
#     activation (mount table + /sys/block/nbd*) and an inconsistency dies
#     loudly instead of being silently repaired.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use JSON::PP ();
use File::Path ();
use PVE::Tools qw(run_command file_read_firstline);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

my $QEMU_IMG = '/usr/bin/qemu-img';
my $QEMU_NBD = '/usr/bin/qemu-nbd';
my $QEMU_SERVER_DIR = '/etc/pve/qemu-server';

use constant {
    FMT => 'qcow2',
    SIDECAR_EXT => '.qbind.json',
};

sub api {
    return 15;
}

sub type {
    return 'qcowbind';
}

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }, { images => 1, rootdir => 1 }],
        format  => [{ qcow2 => 1 }, 'qcow2'],
    };
}

sub properties {
    return {
        # Inherited 'path' is the directory holding the .qcow2 files (ideally
        # a ZFS dataset mount such as /SSD-600G/qcowbind so pool snapshots
        # cover them).
        'mountdir' => {
            description => "Host directory where volumes are mounted for bind " .
                "into LXC containers (e.g. /mnt/qcowbind).",
            type        => 'string',
            default     => '/mnt/qcowbind',
        },
    };
}

sub options {
    return {
        nodes    => { optional => 1 },
        disable  => { optional => 1 },
        content  => { optional => 1 },
        path     => { optional => 1 },
        mountdir => { optional => 1 },
    };
}

# Volname grammar: 'qb-<name>.qcow2'. Volumes are SHARED across CTs, so no
# vmid is embedded in the name and parse_volname returns an undefined vmid.
# This is a deliberate (documented) deviation from PVE conventions: vzdump and
# vmid-scoped listing do not apply to shared volumes.
sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^qb-([a-zA-Z0-9._-]+)\.qcow2$/) {
        return ('rootdir', $volname, undef, undef, undef, undef, FMT);
    }
    die "unable to parse qcowbind volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "snapshots are not supported by qcowbind\n" if defined($snapname);
    my $vtype = ($class->parse_volname($volname))[0];
    return "$scfg->{path}/$volname";
}

# The path exposed to the CT bind layer: the host mountpoint of the mounted
# filesystem. This is what lxc.mount.entry bind lines reference.
sub bind_path {
    my ($class, $scfg, $volname) = @_;

    my (undef, $volname_stripped) = ($volname =~ m/^(qb-[a-zA-Z0-9._-]+)\.qcow2$/);
    $volname_stripped //= $volname;
    my $mountdir = $scfg->{mountdir} // '/mnt/qcowbind';
    return "$mountdir/$volname_stripped";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshots are not supported by qcowbind\n" if defined($snapname);
    my $image = $class->path($scfg, $volname);
    return wantarray ? ($image, undef, 'rootdir') : $image;
}

#######################################
# Run a command and die on failure.
# Arguments:
#   @argv - the command and its arguments
# Outputs:
#   Nothing.
# Returns:
#   True when the command exited zero, throws otherwise.
#######################################
sub _run {
    my @argv = @_;
    run_command(\@argv, errmsg => "qcowbind: command failed: @argv");
    return 1;
}

#######################################
# Run a command and capture its stdout.
# Arguments:
#   @argv - the command and its arguments
# Outputs:
#   Nothing.
# Returns:
#   The captured stdout as a string, or undef when the command failed.
#######################################
sub _run_out {
    my @argv = @_;
    my $out = '';
    eval {
        run_command(\@argv, outfunc => sub { $out .= $_[0] // '' });
    };
    return $@ ? undef : $out;
}

#######################################
# Read the JSON sidecar of a volume, if present.
# Arguments:
#   $class - the plugin class
#   $scfg  - the storage configuration hash
#   $volname - the volume name ('qb-<name>.qcow2')
# Outputs:
#   Nothing.
# Returns:
#   The decoded sidecar hash, or an empty hash when absent or unreadable.
#######################################
sub _sidecar_get {
    my ($class, $scfg, $volname) = @_;

    my $file = $class->path($scfg, $volname) . SIDECAR_EXT;
    return {} if !-f $file;
    my $raw = eval {
        local $/;
        my $content = '';
        if (open(my $fh, '<', $file)) { $content = <$fh>; }
        $content;
    } // '';
    die "qcowbind: cannot read sidecar $file\n" if !defined($raw);
    my $data = eval { JSON::PP->new->decode($raw) } // {};
    die "qcowbind: invalid JSON in sidecar $file\n" if ref($data) ne 'HASH';
    return $data;
}

#######################################
# Write the JSON sidecar of a volume.
# Arguments:
#   $class - the plugin class
#   $scfg  - the storage configuration hash
#   $volname - the volume name
#   $data  - the hash to persist (nbd, mount, bound CTs, format, created)
# Outputs:
#   Writes the sidecar file next to the image, 0600.
# Returns:
#   True on success, throws otherwise.
#######################################
sub _sidecar_set {
    my ($class, $scfg, $volname, $data) = @_;

    my $file = $class->path($scfg, $volname) . SIDECAR_EXT;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $dir = $class->path($scfg, $volname);
    $dir =~ s{/[^/]+$}{};
    File::Path::make_path($dir);
    open(my $fh, '>', $file) or die "qcowbind: cannot write sidecar $file: $!\n";
    print $fh $json;
    close($fh);
    chmod(0600, $file);
    return 1;
}

#######################################
# Find every KVM VM config line referencing a qcowbind volume (by volid,
# file path or bind mountpoint) and return the offending VMIDs.
# Arguments:
#   $class - the plugin class
#   $scfg  - the storage configuration hash
#   $volname - the volume name
# Outputs:
#   Nothing.
# Returns:
#   The sorted list of VMIDs whose qemu-server config references the volume.
#######################################
sub _vm_users {
    my ($class, $scfg, $volname) = @_;

    my $image = $class->path($scfg, $volname);
    my %found;
    return [] if !-d $QEMU_SERVER_DIR;
    if (opendir(my $dh, $QEMU_SERVER_DIR)) {
        while (defined(my $fn = readdir($dh))) {
            next if $fn !~ m/^(\d+)\.conf$/;
            my $vmid = $1;
            if (open(my $fh, '<', "$QEMU_SERVER_DIR/$fn")) {
                while (defined(my $line = <$fh>)) {
                    next if $line =~ m/^\s*#/;
                    # Match volid ('storeid:qb-x.qcow2'), raw image path, or
                    # the bind mount path (all are KVM-incompatible usages).
                    if ($line =~ m/:\s*\Q$volname\E\b/
                        || index($line, $image) >= 0
                        || index($line, $class->bind_path($scfg, $volname)) >= 0) {
                        $found{$vmid} = 1;
                        last;
                    }
                }
                close($fh);
            }
        }
        closedir($dh);
    }
    return [ sort { $a <=> $b } keys %found ];
}

#######################################
# Cross-check the sidecar against the real system state.
# Dies loudly on any mismatch — the caller must not trust a mounted volume
# whose recorded state diverges from reality.
# Arguments:
#   $class - the plugin class
#   $scfg  - the storage configuration hash
#   $volname - the volume name
# Outputs:
#   Nothing.
# Returns:
#   The (validated) state hash: { mounted => bool, nbd => dev, mount => path }.
#######################################
sub _audit_state {
    my ($class, $scfg, $volname) = @_;

    my $state = $class->_sidecar_get($scfg, $volname);
    my $mount = $class->bind_path($scfg, $volname);

    my $really_mounted = (-d $mount) &&
        (_run_out(['/usr/bin/findmnt', '-n', '-o', 'TARGET', $mount]) // '') =~ m/\Q$mount\E/ ? 1 : 0;
    my $nbd = $state->{nbd};
    my $nbd_linked;
    if (defined($nbd) && $nbd =~ m/^\/dev\/nbd(\d+)$/) {
        # qemu-nbd holds the device through a PID file exposed by the kernel.
        my $idx = $1;
        my $pid = (_run_out(['/bin/cat', "/sys/block/nbd$idx/pid"]) // '') =~ m/^\d+$/ ? 1 : 0;
        $nbd_linked = $pid;
    }

    if (!$state->{mounted} && $really_mounted) {
        die "qcowbind: $volname is mounted at $mount but NOT recorded in the " .
            "sidecar — manual intervention required, refusing to manage it\n";
    }
    if ($state->{mounted}) {
        die "qcowbind: $volname recorded as mounted on $nbd but the mountpoint " .
            "$mount is missing (stale sidecar) — refusing\n"
            if !$really_mounted;
        if (defined($nbd_linked)) {
            die "qcowbind: $volname recorded on $nbd but that nbd device is not " .
                "held by qemu-nbd (stale sidecar) — refusing\n"
                if !$nbd_linked;
        }
    }
    # Also refuse when the nbd is live but the mount died: half-mounted state.
    if (defined($nbd_linked) && $nbd_linked && !$really_mounted) {
        die "qcowbind: $volname is still connected on $nbd but unmounted at " .
            "$mount — inconsistent state, refusing\n";
    }
    return {
        mounted => $really_mounted,
        nbd     => $nbd,
        mount   => $mount,
    };
}

#######################################
# Pick a free /dev/nbdX and return its device path.
# Arguments:
#   $class - the plugin class
# Outputs:
#   Nothing.
# Returns:
#   The device path, or dies when no free nbd device exists.
#######################################
sub _alloc_nbd {
    my ($class) = @_;

    for my $i (0 .. 63) {
        my $dev = "/dev/nbd$i";
        next if !-e $dev;
        my $pid = '';
        if (open(my $fh, '<', "/sys/block/nbd$i/pid")) { $pid = <$fh> // ''; }
        next if $pid =~ m/^\d+$/;
        return $dev;
    }
    die "qcowbind: no free nbd device (nbd module loaded? modprobe nbd)\n";
}

#######################################
# Activate a volume: nbd connect + FS mount (idempotent, guarded).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
# Outputs:
#   Mounts the volume and updates its sidecar.
# Returns:
#   True.
#######################################
sub _activate_mount {
    my ($class, $scfg, $volname) = @_;

    $class->_audit_state($scfg, $volname);
    my $state = $class->_sidecar_get($scfg, $volname);
    return 1 if $state->{mounted};

    my $kvmids = $class->_vm_users($scfg, $volname);
    die "qcowbind: refusing to mount $volname — referenced by KVM VM(s) @$kvmids; " .
        "a qcowbind volume cannot also be a VM disk\n" if @$kvmids;

    my $image = $class->path($scfg, $volname);
    die "qcowbind: $volname is already attached to a VM/KVM process\n"
        if _run_out(['/usr/bin/fuser', '-vm', $image]);

    my $mount = $class->bind_path($scfg, $volname);
    File::Path::make_path($mount);
    my $nbd = $class->_alloc_nbd();
    _run([$QEMU_NBD, '--connect=' . $nbd, '--read-only=off', $image]);
    _run(['/usr/bin/mount', $nbd, $mount]);
    $class->_sidecar_set($scfg, $volname, {
        mounted => 1,
        nbd     => $nbd,
        mount   => $mount,
        format  => FMT,
        bound_cts => $state->{bound_cts} // [],
    });
    return 1;
}

#######################################
# Deactivate a volume: umount + nbd disconnect (only when nothing is bound).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
# Outputs:
#   Unmounts the volume and updates its sidecar.
# Returns:
#   True.
#######################################
sub _deactivate_mount {
    my ($class, $scfg, $volname) = @_;

    my $state = $class->_sidecar_get($scfg, $volname);
    return 1 if !$state->{mounted};

    if (@{ $state->{bound_cts} // [] }) {
        die "qcowbind: $volname still bound to CT(s) " .
            join(', ', @{ $state->{bound_cts} }) . " — unbind first\n";
    }
    my $mount = $state->{mount} // $class->bind_path($scfg, $volname);
    _run(['/usr/bin/umount', $mount]);
    if (defined(my $nbd = $state->{nbd})) {
        _run([$QEMU_NBD, '--disconnect', $nbd]);
    }
    $class->_sidecar_set($scfg, $volname, {
        mounted => 0,
        nbd     => undef,
        mount   => $mount,
        format  => FMT,
        bound_cts => [],
    });
    return 1;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $st = eval { PVE::Tools::df($scfg->{path}) };
    return (0, 0, 0, 1) if !$st;
    return ($st->{total}, $st->{avail}, $st->{used}, 1);
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "snapshots are not supported by qcowbind\n" if defined($snapname);
    # Activation in a CT lifecycle happens at start: bind mount needs the
    # underlyer mounted. Mid-create (alloc) also hits this path; the volume
    # simply gets its first mount.
    return $class->_activate_mount($scfg, $volname);
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    return 1 if !-f $class->path($scfg, $volname);
    # Best-effort: never block CT teardown here — a failing unmount is left
    # for the next activation to surface through the consistency audit.
    eval { $class->_deactivate_mount($scfg, $volname) };
    warn $@ if $@;
    return 1;
}

# Standard listing so `pvesm list <storeid>` and the GUI content pickers work.
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];
    my $dir = $scfg->{path};
    return $res if !-d $dir;
    if (opendir(my $dh, $dir)) {
        while (defined(my $fn = readdir($dh))) {
            next if $fn !~ m/^(qb-[a-zA-Z0-9._-]+\.qcow2)$/;
            my $file = "$dir/$fn";
            next if !-f $file;
            push @$res, {
                volid  => "$storeid:$fn",
                format => FMT,
                size   => (-s $file),
                vmid   => undef,
            };
        }
        closedir($dh);
    }
    return $res;
}

# Shared volumes live outside any vmid: no vmid-scoped listing applies.
sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    return [] if defined($vmid);
    return $class->SUPER::list_volumes($storeid, $scfg, $vmid, $content_types);
}

sub volume_size_info {
    # Report the VIRTUAL size (what the FS sees), like the dir/qcow2 storages.
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $image = $class->path($scfg, $volname);
    my $out = $class->_run_out([$QEMU_IMG, 'info', '--output=json', $image]);
    return 0 if !defined($out);
    my $info = eval { JSON::PP->new->decode($out) };
    return 0 if ref($info) ne 'HASH';
    return ($info->{'virtual-size'} // 0);
}

#######################################
# Current virtual size of a volume.
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
# Outputs:
#   Nothing.
# Returns:
#   The virtual size in bytes (0 when unknown).
#######################################
sub _virtual_size {
    my ($class, $scfg, $volname) = @_;

    my $image = $class->path($scfg, $volname);
    my $out = $class->_run_out([$QEMU_IMG, 'info', '--output=json', $image]);
    return 0 if !defined($out);
    my $info = eval { JSON::PP->new->decode($out) };
    return ref($info) eq 'HASH' ? ($info->{'virtual-size'} // 0) : 0;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt' - only qcow2 is supported\n"
        if defined($fmt) && $fmt ne FMT;
    die "qcowbind volumes are shared: no vmid-scoped allocation\n"
        if defined($vmid);
    $name //= 'qb-unnamed.qcow2';
    die "allocation without size is not supported\n" if !$size;

    $class->parse_volname($name);
    my $image = "$scfg->{path}/$name";
    die "qcowbind: volume '$name' already exists\n" if -f $image;

    File::Path::make_path($scfg->{path});
    _run([$QEMU_IMG, 'create', '-f', FMT, $image, $size]);
    $class->_sidecar_set($scfg, $name, {
        mounted => 0,
        nbd     => undef,
        mount   => $class->bind_path($scfg, $name),
        format  => FMT,
        bound_cts => [],
        created => time(),
    });
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $vtype = eval { ($class->parse_volname($volname))[0] } // '';
    return undef if $vtype ne 'rootdir';
    my $image = $class->path($scfg, $volname);

    my $kvmids = $class->_vm_users($scfg, $volname);
    die "qcowbind: refusing to remove $volname - referenced by KVM VM(s) @$kvmids\n"
        if @$kvmids;
    my $state = $class->_sidecar_get($scfg, $volname);
    die "qcowbind: $volname is still bound to CT(s) " .
        join(', ', @{ $state->{bound_cts} // [] }) . " — unbind first\n"
        if @{ $state->{bound_cts} // [] };
    if ($state->{mounted}) {
        eval { $class->_deactivate_mount($scfg, $volname) };
        warn $@ if $@;
        my $after = $class->_sidecar_get($scfg, $volname);
        die "qcowbind: $volname is still mounted — remove aborted\n" if $after->{mounted};
    }
    File::Path::remove_tree($class->bind_path($scfg, $volname), { keep_root => 1 }) if -d $class->bind_path($scfg, $volname);
    unlink($image . SIDECAR_EXT);
    unlink($image);
    return undef;
}

#######################################
# Record a CT in the volume bind list (called by the bind helper).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
#   $ctid  - the LXC VMID adding itself
# Outputs:
#   Updates the sidecar.
# Returns:
#   True.
#######################################
sub binder_add_ct {
    my ($class, $scfg, $volname, $ctid) = @_;

    $ctid = int($ctid);
    my $state = $class->_sidecar_get($scfg, $volname);
    my $cts = $state->{bound_cts} // [];
    return 1 if grep { $_ == $ctid } @$cts;
    push @$cts, $ctid;
    @$cts = sort { $a <=> $b } @$cts;
    $state->{bound_cts} = $cts;
    $class->_sidecar_set($scfg, $volname, $state);
    return 1;
}

#######################################
# Remove a CT from the volume bind list (called by the bind helper).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
#   $ctid  - the LXC VMID removing itself
# Outputs:
#   Updates the sidecar.
# Returns:
#   True.
#######################################
sub binder_remove_ct {
    my ($class, $scfg, $volname, $ctid) = @_;

    $ctid = int($ctid);
    my $state = $class->_sidecar_get($scfg, $volname);
    my $cts = [ grep { $_ != $ctid } @{ $state->{bound_cts} // [] } ];
    $state->{bound_cts} = $cts;
    $class->_sidecar_set($scfg, $volname, $state);
    return 1;
}

sub resize_volume {
    my ($class, $scfg, $storeid, $volname, $size) = @_;

    my $cur = $class->_virtual_size($scfg, $volname);
    die "qcowbind: cannot determine current size of $volname\n" if !$cur;

    if ($size >= $cur) {
        # Straight grow: qcow2 grow is metadata-only and safe while mounted.
        _run([$QEMU_IMG, 'resize', $class->path($scfg, $volname), $size]);
        return $size;
    }

    # Shrink: 'qemu-img resize --shrink' only truncates the tail and does NOT
    # return space to the pool. The only real reclamation path is a
    # conversion whose sparse/cloned target omits the freed blocks:
    #   convert to a temporary target, swap it in. Requires the volume NOT
    #   mounted (the FS inside must be shrunk first by the guest anyway).
    my $state = $class->_sidecar_get($scfg, $volname);
    die "qcowbind: refusing to shrink mounted $volname — shrink the filesystem " .
        "inside, unmount, then resize\n" if $state->{mounted};
    die "qcowbind: refusing to shrink bound $volname — unbind all CTs first\n"
        if @{ $state->{bound_cts} // [] };

    my $image = $class->path($scfg, $volname);
    my $tmp = "$image.tmp.$$.qcow2";
    _run([$QEMU_IMG, 'convert', '-O', FMT, '--sparse', $image, $tmp]);
    _run([$QEMU_IMG, 'resize', $tmp, $size]);
    _run(['/usr/bin/mv', $tmp, $image]);
    return $size;
}

# create/clone of base images does not apply to shared volumes.
sub create_base { die "create_base is not supported by qcowbind\n"; }
sub clone_image { die "clone_image is not supported by qcowbind\n"; }
sub volume_export { die "volume_export is not supported by qcowbind\n"; }

1;