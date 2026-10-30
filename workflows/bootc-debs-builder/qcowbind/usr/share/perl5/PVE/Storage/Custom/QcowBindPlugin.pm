package PVE::Storage::Custom::QcowBindPlugin;

# ---------------------------------------------------------------------------
# PROTOTYPE v2 — not enabled by default. See README.plugin.md and the wiki
# page "qcowbind-design.md".
#
# A PVE storage plugin backing LXC volumes with qcow2 images on a
# dataset-backed directory storage. The qcow2 IS the volume; the ZFS dataset
# underneath is only the container (pool-level compression + snapshots).
#
# TWO VOLUME FORMATS (v2 arbitration, Gabriel 2026-10-30; neutral naming, no
# workload suffix in any format/plugin/storage name):
#
#   format 'qcow'  — file <name>.qcow (content is qcow2). A PER-CT volume:
#     owned by ONE CT. Its size lives in the CT configuration (rootfs/mp
#     size=), so the standard `pct resize` path applies; the plugin only
#     guarantees the same grow/shrink mechanics as before.
#
#   format 'share' — file <name>.share (content is qcow2). A SHARED volume:
#     bindable by N CTs (multi-writer by design — that is the point). Its
#     size is NEVER written in the CT configuration: the setting is carried
#     by the volume itself (sidecar), so there is exactly ONE resize point,
#     at the plugin/volume level, and every bound CT inherits it
#     (no divergent size between VMs/CTs).
#
# Mount model (host-side, never inside a single CT):
#   qcow2 image -> qemu-nbd connect -> kernel FS mount -> one host mountpoint
#   -> bind-mounted (lxc.mount.entry) into the CT (or N CTs for 'share').
#
# Lifecycle via the standard PVE storage API, so everything is native UI:
#   alloc_image   -> qemu-img create
#   free_image    -> refuse if attached, unmount, disconnect nbd, remove file
#   resize_volume -> grow: qemu-img resize; shrink: qemu-img convert to a
#                    sparse temp file + swap (the only path that returns
#                    blocks). Shares ONLY resize through the plugin-side
#                    helper (see RESIZE POLICY below).
#   activate_volume / deactivate_volume -> nbd connect + FS mount / unmount
#
# RESIZE POLICY:
#   - a 'share' volume refuses ANY resize coming through the CT volume path
#     (`pct resize` writes a size in the CT conf — exactly what shares must
#     avoid). A share is only resized through the dedicated plugin-side
#     helper `qcowbind-resize`, which marks the call with
#     QCOWBIND_DIRECT_RESIZE=1; any other caller dies.
#   - a 'qcow' volume keeps the standard path: `pct resize` (grow, and
#     shrink through the same plugin-side convert+swap when unmounted and
#     unbound).
#   - shrink of either format requires: filesystem shrunk inside, volume
#     unmounted, no CT bound. Grow is metadata-only and safe while mounted.
#
# Guards:
#   - refusing to attach the qcow2 as a KVM VM disk is permanent: a VM
#     consumes a volume through virtiofs sharing of the SAME host-side
#     mount (virtiofsN line pointing at bind_path) — multi-consumer VM + CT
#     binding of one share by design; direct disk attach dies;
#   - a 'qcow' volume is owned by exactly ONE CT (bind list guard);
#   - a JSON sidecar (<vol>.qbind.json) records nbd device, mountpoint,
#     bound CTs and format; it is cross-checked against the real system
#     state at every activation (mount table + /sys/block/nbd*) and an
#     inconsistency dies loudly instead of being silently repaired.
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
# The qemu-server config dir is overridable (sandboxed spec tests); on a PVE
# host it is always /etc/pve/qemu-server.
my $QEMU_SERVER_DIR_DEFAULT = '/etc/pve/qemu-server';
sub _qemu_server_dir { return $ENV{QCOWBIND_QEMU_SERVER_DIR} // $QEMU_SERVER_DIR_DEFAULT; }
# nbd device/sysfs roots are overridable too (sandboxed spec tests; on a real
# host these always stay /dev and /sys/block).
my $NBD_DEV_BASE_DEFAULT = '/dev';
my $NBD_SYS_DIR_DEFAULT = '/sys/block';
sub _nbd_dev_base { return $ENV{QCOWBIND_NBD_DEV_BASE} // $NBD_DEV_BASE_DEFAULT; }
sub _nbd_sys_dir { return $ENV{QCOWBIND_NBD_SYS_DIR} // $NBD_SYS_DIR_DEFAULT; }

use constant {
    FILE_FORMAT => 'qcow2',           # on-disk image format of BOTH formats
    SIDECAR_EXT => '.qbind.json',
    # The marker set by the qcowbind-resize helper: the only sanctioned
    # caller of resize_volume() on a 'share' volume.
    DIRECT_RESIZE_ENV => 'QCOWBIND_DIRECT_RESIZE',
};

my $QCOW_RE = qr/^([a-zA-Z0-9][a-zA-Z0-9._-]*)\.qcow$/;
my $SHARE_RE = qr/^([a-zA-Z0-9][a-zA-Z0-9._-]*)\.share$/;

sub api {
    return 15;
}

sub type {
    return 'qcowbind';
}

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }, { images => 1, rootdir => 1 }],
        format  => [{ qcow => 1, share => 1 }, 'qcow', 'share'],
    };
}

sub properties {
    return {
        # Inherited 'path' is the directory holding the .qcow/.share files
        # (ideally a ZFS dataset mount such as /SSD-600G/qcowbind so pool
        # snapshots cover them).
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

#######################################
# Volume format ('qcow' or 'share') from the volname, or dies.
# Arguments:
#   $volname - the volume name
# Outputs:
#   Nothing.
# Returns:
#   The format string 'qcow' or 'share'.
#######################################
sub _volformat {
    my ($volname) = @_;

    return 'qcow'  if $volname =~ $QCOW_RE;
    return 'share' if $volname =~ $SHARE_RE;
    die "unable to parse qcowbind volume name '$volname'\n";
}

# Volname grammar: '<name>.qcow' (per-CT) or '<name>.share' (shared). No
# vmid is embedded in either name: a .qcow carries the size in the CT conf
# (which references the volid), a .share is shared by design. Both return a
# rootdir vtype so pct rootfs/mp paths accept them.
sub parse_volname {
    my ($class, $volname) = @_;

    my $fmt = _volformat($volname); # dies on an unknown grammar
    return ('rootdir', $volname, undef, undef, undef, undef, $fmt);
}

# The path of the backing image file — internal use only (alloc, resize,
# sidecar, guards). The public path() below returns the host mountpoint so
# the native mp binding path (and the bind helper) reference the mounted
# filesystem, never the raw qcow2 file.
sub _image_path {
    my ($class, $scfg, $volname) = @_;

    return "$scfg->{path}/$volname";
}

# Like dir storages, path() exposes the volume DIRECTORY the consumer binds:
# the host mountpoint of the mounted filesystem. This is what PVE binds for
# mp volumes and what lxc.mount.entry lines reference.
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "snapshots are not supported by qcowbind\n" if defined($snapname);
    _volformat($volname);
    return $class->bind_path($scfg, $volname);
}

# The path exposed to the CT bind layer: the host mountpoint of the mounted
# filesystem. This is what lxc.mount.entry bind lines reference.
sub bind_path {
    my ($class, $scfg, $volname) = @_;

    my ($base) = ($volname =~ m/^([a-zA-Z0-9][a-zA-Z0-9._-]*)\.(?:qcow|share)$/);
    $base //= $volname;
    my $mountdir = $scfg->{mountdir} // '/mnt/qcowbind';
    return "$mountdir/$base";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshots are not supported by qcowbind\n" if defined($snapname);
    my $mount = $class->bind_path($scfg, $volname);
    return wantarray ? ($mount, undef, 'rootdir') : $mount;
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
    @argv = @{ $argv[0] } if @argv == 1 && ref($argv[0]) eq 'ARRAY';
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
    shift @argv if !ref($argv[0]);     # drop the invocant from a method call
    @argv = @{ $argv[0] } if @argv == 1 && ref($argv[0]) eq 'ARRAY';
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
#   $volname - the volume name ('<name>.qcow' or '<name>.share')
# Outputs:
#   Nothing.
# Returns:
#   The decoded sidecar hash, or an empty hash when absent or unreadable.
#######################################
sub _sidecar_get {
    my ($class, $scfg, $volname) = @_;

    my $file = $class->_image_path($scfg, $volname) . SIDECAR_EXT;
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

    my $file = $class->_image_path($scfg, $volname) . SIDECAR_EXT;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $dir = $class->_image_path($scfg, $volname);
    $dir =~ s{/[^/]+$}{};
    File::Path::make_path($dir);
    open(my $fh, '>', $file) or die "qcowbind: cannot write sidecar $file: $!\n";
    print $fh $json;
    close($fh);
    chmod(0600, $file);
    return 1;
}

#######################################
# Scan every KVM VM config for references to a qcowbind volume (by volid,
# backing image path) and classify them.
# Direct attach of the qcow2 as a VM disk is NEVER allowed. A virtiofs share
# (virtiofsN line pointing at the plugin host-side mountpoint) is the
# sanctioned way for a VM to consume the SAME host-side mount as the bound
# LXC CTs — allowed and recorded.
# Arguments:
#   $class - the plugin class
#   $scfg  - the storage configuration hash
#   $volname - the volume name
# Outputs:
#   Nothing.
# Returns:
#   Two sorted VMID lists: [ disks, virtiofs ] — disks = offenders whose
#   config attaches the volume as a disk, virtiofs = legal virtiofs sharers.
#######################################
sub _vm_refs {
    my ($class, $scfg, $volname) = @_;

    my $image = $class->_image_path($scfg, $volname);
    my $mount = $class->bind_path($scfg, $volname);
    my (%disks, %virtiofs);
    my $qsdir = $class->_qemu_server_dir();
    return [[], []] if !-d $qsdir;
    if (opendir(my $dh, $qsdir)) {
        while (defined(my $fn = readdir($dh))) {
            next if $fn !~ m/^(\d+)\.conf$/;
            my $vmid = $1;
            if (open(my $fh, '<', "$qsdir/$fn")) {
                while (defined(my $line = <$fh>)) {
                    next if $line =~ m/^\s*#/;
                    my $refers = ($line =~ m/:\s*\Q$volname\E\b/
                        || index($line, $image) >= 0);
                    # virtiofsN lines reference the host mountpoint only —
                    # the sanctioned VM sharing path, never a disk attach.
                    if ($line =~ m/^virtiofs\d+:\s/) {
                        if (index($line, $mount) >= 0
                            || (index($line, $image) >= 0)) {
                            $virtiofs{$vmid} = 1;
                        }
                        next;
                    }
                    # Any other line carrying the volid or the raw backing
                    # image path is a (forbidden or stale) disk attach.
                    if ($refers
                        # A disk line may also point at the mountpoint by
                        # mistake; only attach lines count, virtiofs ones
                        # were handled above.
                        || ($line =~ m/^(?:scsi|virtio|sata|ide|efidisk|tpm?)\d+:\s/
                            && index($line, $mount) >= 0)) {
                        $disks{$vmid} = 1;
                        last;
                    }
                }
                close($fh);
            }
        }
        closedir($dh);
    }
    return [ [ sort { $a <=> $b } keys %disks ],
             [ sort { $a <=> $b } keys %virtiofs ] ];
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
    my $devbase = $class->_nbd_dev_base();
    if (defined($nbd) && $nbd =~ m/^\Q$devbase\E\/nbd(\d+)$/) {
        # qemu-nbd holds the device through a PID file exposed by the kernel.
        my $idx = $1;
        my $pid = (_run_out(['/bin/cat', $class->_nbd_sys_dir() . "/nbd$idx/pid"]) // '') =~ m/^\d+$/ ? 1 : 0;
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
        my $dev = $class->_nbd_dev_base() . "/nbd$i";
        next if !-e $dev;
        my $pid = '';
        if (open(my $fh, '<', $class->_nbd_sys_dir() . "/nbd$i/pid")) { $pid = <$fh> // ''; }
        next if $pid =~ m/^\d+$/;
        return $dev;
    }
    die "qcowbind: no free nbd device (nbd module loaded? modprobe nbd)\n";
}

#######################################
# Activate a volume: nbd connect + FS mount (idempotent, guarded).
# Arguments:
#   $class - the plugin class
#   $scfg - storage config
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

    my ($diskids, $virtiofs) = @{ $class->_vm_refs($scfg, $volname) };
    die "qcowbind: refusing to mount $volname — attached as a VM disk by " .
        "@$diskids (a qcowbind volume cannot be a VM disk; VM sharing goes " .
        "through virtiofs — see README)\n" if @$diskids;
    warn "qcowbind: $volname also shared to VM(s) @$virtiofs via virtiofs\n"
        if @$virtiofs;

    my $image = $class->_image_path($scfg, $volname);
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
        format  => _volformat($volname),
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
        format  => _volformat($volname),
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

    return 1 if !-f $class->_image_path($scfg, $volname)
        && !-f $class->_image_path($scfg, $volname) . SIDECAR_EXT;
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
            next if $fn !~ m/^([a-zA-Z0-9][a-zA-Z0-9._-]*\.(?:qcow|share))$/;
            my $file = "$dir/$fn";
            next if !-f $file;
            push @$res, {
                volid  => "$storeid:$fn",
                format => (eval { _volformat($fn) } // FILE_FORMAT),
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

    return $class->_virtual_size($scfg, $volname);
}

#######################################
# Current virtual size of a volume.
# Arguments:
#   $class - the plugin class
#   $scfg - storage config
#   $volname - volume name
# Outputs:
#   Nothing.
# Returns:
#   The virtual size in bytes (0 when unknown).
#######################################
sub _virtual_size {
    my ($class, $scfg, $volname) = @_;

    my $image = $class->_image_path($scfg, $volname);
    my $out = $class->_run_out([$QEMU_IMG, 'info', '--output=json', $image]);
    return 0 if !defined($out);
    my $info = eval { JSON::PP->new->decode($out) };
    return ref($info) eq 'HASH' ? ($info->{'virtual-size'} // 0) : 0;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    # $fmt here is the volume format ('qcow' or 'share'); the on-disk image
    # is always a qcow2 file.
    die "unsupported format '$fmt' - only 'qcow' and 'share' are supported\n"
        if defined($fmt) && $fmt ne 'qcow' && $fmt ne 'share';
    die "allocation without size is not supported\n" if !$size;
    $name //= 'unnamed.' . ($fmt // 'share');

    my $volfmt = _volformat($name); # dies on an unknown grammar
    my $image = $class->_image_path($scfg, $name);
    die "qcowbind: volume '$name' already exists\n" if -f $image;

    File::Path::make_path($scfg->{path});
    _run([$QEMU_IMG, 'create', '-f', FILE_FORMAT, $image, $size]);
    $class->_sidecar_set($scfg, $name, {
        mounted => 0,
        nbd     => undef,
        mount   => $class->bind_path($scfg, $name),
        format  => $volfmt,
        size    => $size,
        bound_cts => [],
        created => time(),
        # A per-CT ('qcow') volume records its owning CT when known at alloc
        # time; a share never carries one.
        owner   => ($volfmt eq 'qcow' && defined($vmid)) ? int($vmid) : undef,
    });
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $vtype = eval { ($class->parse_volname($volname))[0] } // '';
    return undef if $vtype ne 'rootdir';
    my $image = $class->_image_path($scfg, $volname);

    my ($diskids, undef) = @{ $class->_vm_refs($scfg, $volname) };
    die "qcowbind: refusing to remove $volname - attached as a VM disk by " .
        "@$diskids\n" if @$diskids;
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
# A 'qcow' volume is owned by exactly ONE CT — a second bind dies. A 'share'
# volume accepts any number of binds (multi-writer is its purpose).
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
    my $fmt = _volformat($volname);
    my $state = $class->_sidecar_get($scfg, $volname);
    my $cts = $state->{bound_cts} // [];
    return 1 if grep { $_ == $ctid } @$cts;
    die "qcowbind: $volname is a per-CT volume already owned by CT(s) " .
        join(', ', @$cts) . " — a 'qcow' volume cannot be bound to a second CT\n"
        if $fmt eq 'qcow' && @$cts;
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

#######################################
# Resize a volume.
# RESIZE POLICY:
#   - 'share': the size lives with the volume, never in the CT conf. Only
#     the plugin-side helper (QCOWBIND_DIRECT_RESIZE=1 in the environment)
#     may resize one; `pct resize` or any other caller dies. One resize
#     point, at the volume level, for every bound CT.
#   - 'qcow': the size lives in the CT conf; the standard `pct resize` path
#     routes here and is allowed for grows and shrinks alike.
#   - shrink (both formats): requires an unmounted, unbound volume — the
#     filesystem inside must have been shrunk first; the reclamation uses a
#     sparse convert + swap (the only path that actually returns blocks).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $storeid - the storage id
#   $volname - volume name
#   $size  - the new (absolute) size in bytes
# Outputs:
#   Resizes the image file and updates the sidecar size for a share.
# Returns:
#   The new size.
#######################################
sub resize_volume {
    my ($class, $scfg, $storeid, $volname, $size) = @_;

    my $fmt = _volformat($volname);
    my $cur = $class->_virtual_size($scfg, $volname);
    die "qcowbind: cannot determine current size of $volname\n" if !$cur;

    if ($fmt eq 'qcow' && !$ENV{+DIRECT_RESIZE_ENV}) {
        # Standard path: size lives in the CT conf, `pct resize` is fine.
    } elsif ($fmt eq 'share' && !$ENV{+DIRECT_RESIZE_ENV}) {
        die "qcowbind: $volname is a shared volume — its size is NOT in the CT " .
            "configuration and cannot be resized through it; resize it once at " .
            "the volume level with qcowbind-resize\n";
    }

    if ($size >= $cur) {
        # Straight grow: qcow2 grow is metadata-only and safe while mounted.
        _run([$QEMU_IMG, 'resize', $class->_image_path($scfg, $volname), $size]);
        $class->_sidecar_update_size($scfg, $volname, $size);
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

    my $image = $class->_image_path($scfg, $volname);
    my $tmp = "$image.tmp.$$.qcow2";
    _run([$QEMU_IMG, 'convert', '-O', FILE_FORMAT, '--sparse', $image, $tmp]);
    _run([$QEMU_IMG, 'resize', $tmp, $size]);
    _run(['/usr/bin/mv', $tmp, $image]);
    $class->_sidecar_update_size($scfg, $volname, $size);
    return $size;
}

#######################################
# Keep the sidecar 'size' in step after a volume-level resize (shares carry
# their size there; harmless — and kept in step — for 'qcow' too).
# Arguments:
#   $class - the plugin class
#   $scfg  - storage config
#   $volname - volume name
#   $size  - the new size
# Outputs:
#   Updates the sidecar.
# Returns:
#   True.
#######################################
sub _sidecar_update_size {
    my ($class, $scfg, $volname, $size) = @_;

    my $state = $class->_sidecar_get($scfg, $volname);
    return 1 if !keys %$state;
    $state->{size} = $size;
    $class->_sidecar_set($scfg, $volname, $state);
    return 1;
}

# create/clone of base images does not apply to qcowbind volumes.
sub create_base { die "create_base is not supported by qcowbind\n"; }
sub clone_image { die "clone_image is not supported by qcowbind\n"; }
sub volume_export { die "volume_export is not supported by qcowbind\n"; }

1;