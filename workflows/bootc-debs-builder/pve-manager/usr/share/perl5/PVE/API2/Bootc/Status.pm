package PVE::API2::Bootc::Status;

# bootc guest start/stop/status/shutdown/destroy (variant A surfaces S6/S7).
# Shape derived from PVE::API2::LXC::Status (pve-container), rebranded for
# compose2bootc: every action shells out to the lifecycle wrapper
# /usr/share/pve-manager/dc/pvect-bootc (which itself delegates to
# pvect-ostree) as UPID tasks. The pve-container / LXC runtime is never
# touched; no v1 HA, no vzdump, no migration (see the plan's non-goals).

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param file_set_contents);
use PVE::Exception qw(raise raise_param_exc);
use PVE::INotify;
use PVE::Cluster;
use PVE::AccessControl;
use PVE::Storage;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Bootc;

use base qw(PVE::RESTHandler);

my $wrapper = '/usr/share/pve-manager/dc/pvect-bootc';

__PACKAGE__->register_method({
    name => 'vmcmdidx',
    path => '',
    method => 'GET',
    proxyto => 'node',
    description => "Directory index",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                subdir => { type => 'string' },
            },
        },
        links => [{ rel => 'child', href => "{subdir}" }],
    },
    code => sub {
        my ($param) = @_;

        # test the guest exists (and is a bootc guest)
        PVE::Bootc::load_config($param->{vmid});

        my $res = [
            { subdir => 'current' },
            { subdir => 'start' },
            { subdir => 'stop' },
            { subdir => 'shutdown' },
        ];

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'vm_status',
    path => 'current',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Get container status.",
    permissions => {
        description => "You can get the status only of your own bootc guests.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $node = extract_param($param, 'node');
        my $conf = PVE::Bootc::load_config($vmid, $node);

        return {
            status => PVE::Bootc::conf_status($conf),
            name => $conf->{name} // $vmid,
            description => $conf->{description} // '',
        };
    },
});

# shared body for start/stop/shutdown: run the wrapper as a task
my $run_lifecycle = sub {
    my ($vmid, $node, $action, $user, $timeout) = @_;

    my $rpcenv = PVE::RPCEnvironment::get();
    $rpcenv->{type} = 'priv'; # to start tasks in background

    my $conf = PVE::Bootc::load_config($vmid, $node);
    die "guest is already in the requested state\n"
        if $action eq 'start' && PVE::Bootc::conf_status($conf) eq 'running';
    die "guest is not running\n"
        if $action ne 'start' && PVE::Bootc::conf_status($conf) eq 'stopped';

    my $cmd = [$wrapper, $action, $vmid];
    push @$cmd, '--timeout', "$timeout" if defined($timeout);

    return $rpcenv->fork_worker(
        "bootc$action", $vmid, $user,
        sub { PVE::Tools::run_command($cmd, errmsg => "bootc $action $vmid failed"); });
};

__PACKAGE__->register_method({
    name => 'vm_start',
    path => 'start',
    protected => 1,
    method => 'POST',
    proxyto => 'node',
    description => "Start a bootc container.",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.PowerMgmt']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        my $node = $param->{node};
        my $vmid = $param->{vmid};
        my $authuser = $rpcenv->get_user();
        return $run_lifecycle->($vmid, $node, 'start', $authuser);
    },
});

__PACKAGE__->register_method({
    name => 'vm_shutdown',
    path => 'shutdown',
    method => 'POST',
    proxyto => 'node',
    description => "Shutdown a bootc container (graceful stop).",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.PowerMgmt']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            timeout => get_standard_option('timeout-schema', { default => 30 }),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        $rpcenv->{type} = 'priv'; # to start tasks in background

        return $run_lifecycle->(
            $param->{vmid}, $param->{node}, 'shutdown', $rpcenv->get_user(),
            $param->{timeout});
    },
});

__PACKAGE__->register_method({
    name => 'vm_stop',
    path => 'stop',
    protected => 1,
    method => 'POST',
    proxyto => 'node',
    description => "Stop a bootc container (hard).",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.PowerMgmt']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        my $node = $param->{node};
        my $vmid = $param->{vmid};
        my $authuser = $rpcenv->get_user();
        return $run_lifecycle->($vmid, $node, 'stop', $authuser);
    },
});

__PACKAGE__->register_method({
    name => 'vm_destroy',
    path => 'destroy',
    protected => 1,
    method => 'DELETE',
    proxyto => 'node',
    description => "Destroy a bootc container (ostree deployment kept for rollback).",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.Allocate']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        PVE::Bootc::load_config($param->{vmid}, $param->{node});

        return $rpcenv->fork_worker(
            'bootcdestroy', $param->{vmid}, $rpcenv->get_user(),
            sub { PVE::Tools::run_command([$wrapper, 'destroy', $param->{vmid}],
                errmsg => "bootc destroy $param->{vmid} failed"); });
    },
});

__PACKAGE__->register_method({
    name => 'read_compose',
    path => 'compose',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.Audit']] },
    description => "The recorded compose source of the guest.",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $conf = PVE::Bootc::load_config($param->{vmid}, $param->{node});
        die "guest $param->{vmid} has no recorded compose source\n" if !$conf->{compose};
        return PVE::Tools::file_get_contents($conf->{compose});
    },
});

__PACKAGE__->register_method({
    name => 'rollback',
    path => 'rollback',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.PowerMgmt']] },
    description => "Re-activate the previous deployment (ostree rollback).",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        PVE::Bootc::load_config($param->{vmid}, $param->{node});

        return $rpcenv->fork_worker(
            'bootcrollback', $param->{vmid}, $authuser,
            sub { PVE::Tools::run_command([$wrapper, 'rollback', $param->{vmid}],
                errmsg => "bootc rollback $param->{vmid} failed"); });
    },
});

1;
