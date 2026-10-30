# PVE::Tools stub — sandboxed spec tests for the qcowbind plugin.
# Emulates the handful of PVE::Tools functions the plugin uses, recording
# every command in a global list the test can assert against.
package PVE::Tools;

use strict;
use warnings;
use JSON::PP ();
use Exporter 'import';
our @EXPORT_OK = qw(run_command file_read_firstline df);

# Test-visible state (also reachable through PVE::Tools::test_state()).
my $STATE = {
    commands => [],       # every argv handed to run_command
    sizes    => {},       # qemu-image virtual sizes, keyed by file
    mounts   => {},       # mountpoint -> device (findmnt semantics)
    nbds     => {},       # /dev/nbdX -> held?
    failures => {},       # argv[0] -> die when invoked
};

sub test_state { return $STATE; }

my $GB = 1024 * 1024 * 1024;

sub _basename { my ($p) = @_; $p =~ s{^.*/}{}; return $p; }

sub run_command {
    my ($cmd, %opts) = @_;
    my @argv = ref($cmd) ? @$cmd : ($cmd);
    push @{ $STATE->{commands} }, [@argv];
    my $bin = _basename($argv[0] // '');
    die $opts{errmsg} . "\n" if exists $STATE->{failures}{$bin};

    if ($bin eq 'qemu-img') {
        my $op = $argv[1];
        if ($op eq 'info') {
            my ($file) = grep { m/[\/]/ } @argv[2 .. $#argv];
            $file //= '';
            my $size = $STATE->{sizes}{$file} // 10 * $GB;
            my $out = JSON::PP->new->encode({ 'virtual-size' => $size });
            if ($opts{outfunc}) { $opts{outfunc}->($out); return 1; }
            return $out;
        }
        if ($op eq 'resize') {
            my ($file, $size) = ($argv[2], $argv[3]);
            $STATE->{sizes}{$file} = int($size);
            return 1;
        }
        if ($op eq 'convert') {
            my ($src, $dst) = ($argv[-2], $argv[-1]);
            $STATE->{sizes}{$dst} = int($STATE->{sizes}{$src} // 10 * $GB);
            open(my $fh, '>', $dst) or die "convert: cannot create $dst\n";
            close($fh);
            return 1;
        }
        if ($op eq 'create') {
            my ($file, $size) = ($argv[-2], $argv[-1]);
            $STATE->{sizes}{$file} = int($size);
            open(my $fh, '>', $file) or die "create: cannot create $file\n";
            close($fh);
            return 1;
        }
        die "qemu-img: unknown op '$op'";
    }
    if ($bin eq 'qemu-nbd') {
        my $arg = $argv[1] // '';
        if ($arg =~ m/--connect=(\/dev\/nbd\d+)/) {
            $STATE->{nbds}{$1} = 1;
        } elsif ($arg eq '--disconnect') {
            $STATE->{nbds}{$argv[2]} = 0;
        }
        return 1;
    }
    if ($bin eq 'mount') {
        $STATE->{mounts}{$argv[2]} = $argv[1];
        return 1;
    }
    if ($bin eq 'umount') {
        delete $STATE->{mounts}{$argv[1]};
        return 1;
    }
    if ($bin eq 'findmnt') {
        my $target = $argv[-1];
        return 1 if exists $STATE->{mounts}{$target};
        return 10; # PVE dies with errmsg; not used in tests
    }
    if ($bin eq 'fuser') {
        return 0;
    }
    if ($bin eq 'mv') {
        my ($src, $dst) = ($argv[-2], $argv[-1]);
        $STATE->{sizes}{$dst} = $STATE->{sizes}{$src};
        rename($src, $dst) or die "mv: $src -> $dst: $!\n";
        return 1;
    }
    return 1;
}

sub file_read_firstline {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    my $l = <$fh>;
    close($fh);
    return $l;
}

sub df {
    my ($path) = @_;
    return undef if !-d $path;
    return { total => 100 * $GB, used => 10 * $GB, avail => 90 * $GB };
}

1;