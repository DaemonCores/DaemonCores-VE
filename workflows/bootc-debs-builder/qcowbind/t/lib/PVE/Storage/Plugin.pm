# PVE::Storage::Plugin stub — sandboxed spec tests for qcowbind.
# Only what the plugin needs: a blessed base class with the default
# list_volumes and the standard option helpers.
package PVE::Storage::Plugin;

use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw();

sub new { return bless {}, shift; }

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    return [];
}

1;