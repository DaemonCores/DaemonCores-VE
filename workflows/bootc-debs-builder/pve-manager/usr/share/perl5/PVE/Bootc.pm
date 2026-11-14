package PVE::Bootc;

# bootc guest helpers (variant A, docs/compose-variant-a-plan.md).
# Derived from the LXC support in pve-container (PVE::LXC / Config slice),
# rebranded for compose2bootc: no volume plumbing, no pct machinery - a
# bootc guest is a conf file under nodes/<node>/bootc/<vmid>.conf (key:
# value lines) plus its pvect-ostree registry entry. Its status is carried
# by the `status` line (pvestatd writes it, pvestatd reads it through the
# same file - the conf lives on the cluster fs, so it works cluster-wide).
#
# The guest LIST cannot come from /etc/pve/.vmlist: pmxcfs only registers
# `nodes/<node>/lxc` and `nodes/<node>/qemu-server` as guest directories, so a
# bootc conf never produces a vmlist entry. guests_list therefore reads the
# `bootc` directories themselves (one per node) and unions whatever the
# vmlist may carry, so the API keeps working if a future pve-cluster learns
# the type.

use strict;
use warnings;

use PVE::Tools;
use PVE::INotify;
use PVE::Cluster qw(cfs_read_file);

my $BOOTC_DIR = 'bootc';

# Read and parse a bootc guest conf (key: value lines, '#' comments).
sub load_config {
    my ($vmid, $node) = @_;
    $node //= _node_of_guest($vmid);

    die "guest $vmid is not a bootc guest\n" if !defined($node);

    my $path = "nodes/$node/bootc/$vmid.conf";
    my $raw = eval { cfs_read_raw($path) } // '';
    my $res = {};
    foreach my $line (split(/\n/, $raw)) {
        $line =~ s/^\s+//;
        next if !$line || $line =~ /^#/;
        next if $line !~ /^([^:\s]+):\s*(.*)$/;
        $res->{$1} = $2;
    }
    $res->{vmid} = $vmid;
    $res->{node} = $node;
    return $res;
}

# Raw read through the IPCC mem-db path (no parser registered - we do not
# want cfs_read_file's $file_info cache for a plain text conf).
sub cfs_read_raw {
    my ($path) = @_;

    return PVE::Cluster::get_config($path);
}

# Locate the node owning a bootc guest: the vmlist when it carries the entry,
# else the one node whose bootc conf directory holds <vmid>.conf.
sub _node_of_guest {
    my ($vmid) = @_;

    my $vmlist = PVE::Cluster::get_vmlist() // {};
    my $d = $vmlist->{ids}->{$vmid};
    return $d->{node} if defined($d) && ($d->{type} // '') eq 'bootc';
    foreach my $node (@{ _nodes() }) {
        return $node if -f "/etc/pve/nodes/$node/bootc/$vmid.conf";
    }
    return undef;
}

sub _nodes {
    my $res = eval { PVE::INotify::nodelist() };
    return [sort keys %$res] if $res && %$res;
    # fall back to the directory listing of the cluster fs
    my @nodes;
    if (opendir(my $dh, '/etc/pve/nodes')) {
        while (defined(my $fn = readdir($dh))) {
            next if $fn =~ /^\./;
            push @nodes, $fn if -d "/etc/pve/nodes/$fn";
        }
        closedir($dh);
    }
    return [sort @nodes];
}

# The cluster-wide running state of one bootc guest ('running'/'stopped').
sub conf_status {
    my ($conf) = @_;

    return $conf->{status} // 'stopped';
}

# get_filtered_vmlist() (API2/Nodes) calls $class->is_template() on every
# conf; bootc guests are never templates (templates live on the ostree
# storage), so it is always 0 - same contract as PVE::LXC::Config.
sub is_template { 0 }

sub guest_status {
    my ($vmid, $node) = @_;

    my $conf = eval { load_config($vmid, $node) };
    return 'unknown' if $@;
    return conf_status($conf);
}

# All bootc guest ids on a node (undef = all nodes). Two sources, unioned and
# de-duplicated: the vmlist entries (when pve-cluster knows the type) and the
# conf files actually present under /etc/pve/nodes/<node>/bootc/.
sub guests_list {
    my ($node) = @_;

    my %seen;
    my $res = [];
    my $vmlist = PVE::Cluster::get_vmlist() // {};
    my $ids = $vmlist->{ids} // {};
    foreach my $vmid (keys %$ids) {
        my $id = $ids->{$vmid};
        next if ($id->{type} // '') ne 'bootc';
        next if defined($node) && $id->{node} ne $node;
        next if $seen{$vmid}++;
        push @$res, { vmid => $vmid + 0, node => $id->{node}, type => 'bootc' };
    }
    foreach my $n (@{ defined($node) ? [$node] : _nodes() }) {
        my $dir = "/etc/pve/nodes/$n/$BOOTC_DIR";
        next if !opendir(my $dh, $dir);
        while (defined(my $fn = readdir($dh))) {
            next if $fn !~ m/^(\d+)\.conf$/;
            my $vmid = $1 + 0;
            next if $seen{$vmid}++;
            push @$res, { vmid => $vmid, node => $n, type => 'bootc' };
        }
        closedir($dh);
    }
    return [sort { $a->{vmid} <=> $b->{vmid} } @$res];
}

# Network stanzas of a guest conf, parsed into pct-shaped hashes.
# net0/net1/net2 carry pct keys ("name=eth0,bridge=vmbr0,ip=CIDR,gw=G").
sub conf_networks {
    my ($conf) = @_;

    my $res = [];
    foreach my $slot (0 .. 2) {
        my $raw = $conf->{"net$slot"};
        next if !defined($raw) || $raw eq '';
        my $net = { slot => $slot };
        foreach my $kv (split(/,/, $raw)) {
            my ($k, $v) = split(/=/, $kv, 2);
            next if !defined($v);
            $net->{$k} = $v;
        }
        push @$res, $net;
    }
    return $res;
}

1;
