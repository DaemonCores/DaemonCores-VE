#!/usr/bin/perl
# Spec tests for the qcowbind plugin v2 (sandboxed: every external behaviour
# is emulated by the PVE::Tools stub in t/lib; nothing touches a real CT,
# VM, nbd device or dataset).
#   Run: t/run-tests.sh   (or: PERL5LIB=t/lib perl t/qcowbind-plugin.t)
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../usr/share/perl5";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use PVE::Tools ();
use PVE::Storage::Custom::QcowBindPlugin;

my $GB = 1024 * 1024 * 1024;
my $tmp = tempdir('qcowbind-test.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $scfg = { path => "$tmp/vols", mountdir => "$tmp/mnt", type => 'qcowbind' };
make_path($scfg->{path});
my $C = 'PVE::Storage::Custom::QcowBindPlugin';
local $ENV{QCOWBIND_QEMU_SERVER_DIR} = "$tmp/qemu-server";
$ENV{QCOWBIND_NBD_DEV_BASE} = "$tmp/dev";
$ENV{QCOWBIND_NBD_SYS_DIR} = "$tmp/sysblock";
make_path($ENV{QCOWBIND_NBD_DEV_BASE}, $ENV{QCOWBIND_NBD_SYS_DIR});
for my $i (0 .. 3) {
    # nbd devices exist, none held (empty pid files)
    open(my $fh, '>', "$ENV{QCOWBIND_NBD_DEV_BASE}/nbd$i") or die $!;
    close($fh);
}

sub dies_like {
    my ($code, $re, $label) = @_;
    eval { $code->() };
    like($@, $re, $label);
}

# ---------------------------------------------------------------- grammar ---
{
    my ($vtype, $vname) = eval { $C->parse_volname('ci-scratch.share') };
    ok(!$@ && $vtype eq 'rootdir' && $vname eq 'ci-scratch.share',
        'share volname parses');

    ($vtype) = $C->parse_volname('ct01.qcow');
    cmp_ok($vtype, 'eq', 'rootdir', 'qcow volname parses');

    dies_like(sub { $C->parse_volname('legacy.qcow2') },
        qr/unable to parse/, 'the .qcow2 grammar of v1 is refused');
    dies_like(sub { $C->parse_volname('') }, qr/unable to parse/,
        'an empty volname dies');
    dies_like(sub { $C->parse_volname('bad name.qcow') },
        qr/unable to parse/, 'a space is refused in the name');
    dies_like(sub { $C->parse_volname('-leading-dash.share') },
        qr/unable to parse/, 'a leading dash is refused');
}

# ------------------------------------------------------------ format data ---
{
    my $pd = $C->plugindata();
    is_deeply($pd->{format}, [{ qcow => 1, share => 1 }, 'qcow', 'share'],
        'plugindata declares the two volume formats');
    is($C->type(), 'qcowbind', 'storage type is the neutral qcowbind');
}

# ------------------------------------------------------------- bind path ---
{
    is($C->bind_path($scfg, 'ci-scratch.share'), "$tmp/mnt/ci-scratch",
        'bind_path strips the .share extension');
    is($C->bind_path($scfg, 'ct01.qcow'), "$tmp/mnt/ct01",
        'bind_path strips the .qcow extension');
    is($C->path($scfg, 'ci-scratch.share'), "$scfg->{mountdir}/ci-scratch",
        'public path() exposes the host mountpoint (mp-bind semantics)');
    my $img = $C->_image_path($scfg, 'ci-scratch.share');
    is($img, "$tmp/vols/ci-scratch.share", 'the backing image path stays _image_path');
}

# ----------------------------------------------------------------- alloc ---
{
    my $name = eval { $C->alloc_image(undef, $scfg, undef, 'share', 'ci-scratch.share', 40 * $GB) };
    ok(!$@ && $name eq 'ci-scratch.share', 'alloc a share (size carried by the volume)');
    is(PVE::Tools::test_state->{sizes}{ $C->_image_path($scfg, $name) }, 40 * $GB,
        'qemu-img create ran with the size');
    my $side = $C->_sidecar_get($scfg, 'ci-scratch.share');
    is($side->{format}, 'share', 'sidecar records the share format');
    is($side->{size}, 40 * $GB, 'sidecar carries the volume size (NOT in any CT conf)');

    $name = eval { $C->alloc_image(undef, $scfg, 103, 'qcow', 'ct103.qcow', 10 * $GB) };
    ok(!$@ && $name eq 'ct103.qcow', 'alloc a per-CT qcow with an owning vmid');
    $side = $C->_sidecar_get($scfg, 'ct103.qcow');
    is($side->{format}, 'qcow', 'sidecar records the qcow format');
    is($side->{owner}, 103, 'sidecar records the owning CT');

    dies_like(sub { $C->alloc_image(undef, $scfg, undef, 'qcow2', 'old.qcow2', $GB) },
        qr/only 'qcow' and 'share' are supported/, 'the qcow2 format is refused');
    dies_like(sub { $C->alloc_image(undef, $scfg, undef, 'share', 'ci-scratch.share', $GB) },
        qr/already exists/, 'double alloc dies');
    dies_like(sub { $C->alloc_image(undef, $scfg, undef, 'share', 'nosize.share', 0) },
        qr/allocation without size/, 'a sizeless alloc dies');
}

# ---------------------------------------------------------- resize policy ---
{
    # a SHARE resize without the marker = the CT path -> refusal
    dies_like(sub { $C->resize_volume($scfg, 'qco', 'ci-scratch.share', 50 * $GB) },
        qr/cannot be resized through it/, 'a share refuses a resize through the CT conf path');
    dies_like(sub { $C->resize_volume($scfg, 'qco', 'ci-scratch.share', 50 * $GB) },
        qr/qcowbind-resize/, 'the refusal names the plugin-side helper');

    local $ENV{QCOWBIND_DIRECT_RESIZE} = 1;
    my $new = eval { $C->resize_volume($scfg, 'qco', 'ci-scratch.share', 50 * $GB) };
    ok(!$@ && $new == 50 * $GB, 'the plugin-side marker grows a share');
    is($C->_sidecar_get($scfg, 'ci-scratch.share')->{size}, 50 * $GB,
        'the sidecar size follows the share resize');
    $new = eval { $C->resize_volume($scfg, 'qco', 'ci-scratch.share', 45 * $GB) };
    ok(!$@ && $new == 45 * $GB, 'the plugin-side marker shrinks a free share');
    is($C->_sidecar_get($scfg, 'ci-scratch.share')->{size}, 45 * $GB,
        'the sidecar size follows the shrink too');

    # a QCOW resize keeps the standard path: no marker needed
    my $q = eval { $C->resize_volume($scfg, 'qco', 'ct103.qcow', 20 * $GB) };
    ok(!$@ && $q == 20 * $GB, 'a qcow grows through the standard pct resize path');
    $q = eval { $C->resize_volume($scfg, 'qco', 'ct103.qcow', 15 * $GB) };
    ok(!$@ && $q == 15 * $GB, 'a qcow shrinks (convert+swap) when unmounted/unbound');

    # shrink preconditions: mounted or bound -> refusal (both formats)
    $C->_sidecar_set($scfg, 'ct103.qcow', {
        mounted => 1, nbd => "$tmp/dev/nbd7", mount => $C->bind_path($scfg, 'ct103.qcow'),
        format => 'qcow', bound_cts => [],
    });
    dies_like(sub { $C->resize_volume($scfg, 'qco', 'ct103.qcow', 5 * $GB) },
        qr/refusing to shrink mounted/,'a shrink refuses while mounted');
    $C->_sidecar_set($scfg, 'ct103.qcow', {
        mounted => 0, nbd => undef, mount => $C->bind_path($scfg, 'ct103.qcow'),
        format => 'qcow', bound_cts => [103],
    });
    dies_like(sub { $C->resize_volume($scfg, 'qco', 'ct103.qcow', 5 * $GB) },
        qr/unbind all CTs first/, 'a shrink refuses while a CT is bound');
}

# ------------------------------------------------------------ binder CTs ---
{
    # SHARE: N CTs, the multi-writer case is the design — no guard fires
    ok($C->binder_add_ct($scfg, 'ci-scratch.share', 121), 'CT 121 binds the share');
    ok($C->binder_add_ct($scfg, 'ci-scratch.share', 122), 'CT 122 also binds it (multi-writer by design)');
    is_deeply($C->_sidecar_get($scfg, 'ci-scratch.share')->{bound_cts}, [121, 122],
        'both CTs appear in the share bind list');

    # QCOW: one CT exactly
    ok($C->binder_add_ct($scfg, 'ct103.qcow', 103), 'the owner binds its qcow');
    dies_like(sub { $C->binder_add_ct($scfg, 'ct103.qcow', 122) },
        qr/cannot be bound to a second CT/, 'a second bind on a qcow dies');
    ok($C->binder_remove_ct($scfg, 'ct103.qcow', 103), 'unbind works');
    is_deeply($C->_sidecar_get($scfg, 'ct103.qcow')->{bound_cts}, [], 'the qcow bind list is empty');
}

# ----------------------------------------------------- KVM disk vs virtiofs ---
{
    make_path($ENV{QCOWBIND_QEMU_SERVER_DIR});
    # 200 attaches the share AS A DISK -> always refused
    # 201 shares it to the VM through virtiofs -> sanctioned
    open(my $fh, '>', "$tmp/qemu-server/200.conf");
    print $fh "scsi0: qco:ci-scratch.share,iothread=1,size=45G\n";
    close($fh);
    open($fh, '>', "$tmp/qemu-server/201.conf");
    print $fh "virtiofs0: ciscratch=$tmp/mnt/ci-scratch\n";
    close($fh);

    my ($disks, $virtiofs) = @{ $C->_vm_refs($scfg, 'ci-scratch.share') };
    is_deeply($disks, [200], 'the direct VM-disk attach of a share is flagged');
    is_deeply($virtiofs, [201], 'the virtiofs VM sharing is recognised as sanctioned');

    dies_like(sub { $C->_activate_mount($scfg, 'ci-scratch.share') },
        qr/cannot be a VM disk/, 'activation refuses a share attached as a VM disk');

    # the virtiofs-only VM does NOT block activation
    unlink("$tmp/qemu-server/200.conf");
    local $ENV{QCOWBIND_DIRECT_RESIZE} = 1;
    ok(eval { $C->binder_remove_ct($scfg, 'ci-scratch.share', 121); 1 }, 'unbind 121 for activation');
    my $ok = eval { $C->_activate_mount($scfg, 'ci-scratch.share') };
    diag("activation error: $@") if !$ok;
    ok($ok, 'activation succeeds with a virtiofs-only VM consumer');
    ok(PVE::Tools::test_state->{mounts}{"$tmp/mnt/ci-scratch"}, 'the share is mounted host-side');
    $C->binder_remove_ct($scfg, 'ci-scratch.share', 122); # multi-writer unbind
    ok($C->_deactivate_mount($scfg, 'ci-scratch.share'), 'deactivation unmounts it');
}
# sidecar round trip and list
{
    my $side = $C->_sidecar_get($scfg, 'ci-scratch.share');
    is($side->{format}, 'share', 'the sidecar survives the mount cycle');
    my $list = $C->list_images('qco', $scfg, undef, undef, {});
    my %byid = map { $_->{volid} => $_ } @$list;
    ok($byid{"qco:ci-scratch.share"}, 'list_images lists the share');
    ok($byid{"qco:ct103.qcow"}, 'list_images lists the qcow');
    is($byid{"qco:ci-scratch.share"}{format}, 'share', 'the listed format is the share volume format');
}

done_testing();