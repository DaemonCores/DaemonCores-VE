# PVE::Storage stub — sandboxed spec tests (qcowbind-resize helper).
package PVE::Storage;

use strict;
use warnings;

sub config { return {}; }
sub storage_config { return {}; }
sub activate_storage { return 1; }
sub deactivate_storage { return 1; }
sub resize_volume {
    my ($cfg, $volid, $size) = @_;
    die "not implemented in the sandboxed spec test\n";
    return $size;
}
sub volume_size_info {
    die "not implemented in the sandboxed spec test\n";
    return 0;
}

1;