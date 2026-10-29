package PVE::Bootc;

# bootc guest helpers (variant A, docs/compose-variant-a-plan.md).
# Derived from the LXC support in pve-container (PVE::LXC / Config slice),
# rebranded for compose2bootc: no volume plumbing, no pct machinery - a
# bootc guest is a conf file under nodes/<node>/bootc/<vmid>.conf (key:
# value lines) plus its pvect-ostree registry entry. Its status is carried
# by the `status` line (pvestatd writes it, pvestatd reads it through the
# same file - the conf lives on the cluster fs, so it works cluster-wide).

use strict;
use warnings;

use PVE::Tools;
use PVE::Cluster qw(cfs_read_file get_vmlist);

# Read and parse a bootc guest conf (key: value lines, '#' comments).
sub load_config {
    my ($vmid, $node) = @_;
    my $vmlist = get_vmlist() // {};
    my $d = $vmlist->{ids}->{$vmid};
    $node //= $d->{node} if defined($d);
    die "guest $vmid is not a bootc guest\n" if defined($d) && $d->{type} ne 'bootc';

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
    return $res;
}

# Raw read through the IPCC mem-db path (no parser registered - we do not
# want cfs_read_file's $file_info cache for a plain text conf).
sub cfs_read_raw {
    my ($path) = @_;

    return PVE::Cluster::get_config($path);
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

# All bootc guest ids on a node (undef = all nodes), from the vmlist.
sub guests_list {
    my ($node) = @_;

    my $vmlist = get_vmlist() // {};
    my $ids = $vmlist->{ids} // {};
    return [grep { $_->{type} eq 'bootc' && (!defined($node) || $_->{node} eq $node) }
        values %$ids];
}

1;