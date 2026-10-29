package PVE::API2::Bootc;

# bootc guest API root (variant A, surfaces S7 of
# docs/compose-variant-a-plan.md). Shape derived from PVE::API2::LXC
# (pve-container), rebranded for compose2bootc: create from a published
# seed template, compose-refresh of a guest. Permissions reuse the
# standard VM.* privileges so ACLs behave identically. The conf is created
# by pvect-bootc (registered in the vmlist by pmxcfs via the memdb hooks).

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param file_get_contents file_set_contents);
use PVE::Exception qw(raise raise_param_exc raise_perm_exc);
use PVE::INotify;
use PVE::Cluster;
use PVE::AccessControl;
use PVE::Storage;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::API2::Bootc::Status;
use PVE::Bootc;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Bootc::Status",
    path => '{vmid}',
});

my $wrapper = '/usr/share/pve-manager/dc/pvect-bootc';

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => { user => 'all' },
    description => "Bootc container index (per node).",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                vmid => get_standard_option('pve-vmid'),
                status => { type => 'string', optional => 1 },
            },
        },
        links => [{ rel => 'child', href => "{vmid}" }],
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $res = [];
        foreach my $entry (@{ PVE::Bootc::guests_list($param->{node}) }) {
            my $vmid = $entry->{vmid};
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);
            my $conf = eval { PVE::Bootc::load_config($vmid, $entry->{node}) };
            push @$res, {
                vmid => $vmid + 0,
                node => $entry->{node},
                name => $conf->{name} // $entry->{node},
                status => PVE::Bootc::conf_status($conf),
            };
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'create',
    path => '',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    description => "Create a bootc container from a published seed template.",
    permissions => { check => ['perm', '/vms/{vmid}', ['VM.Allocate']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            archive => {
                description => "Published seed template, e.g. 'ostree:vztmpl/<stack>.tar.gz'.",
                type => 'string', format => 'pve-volume-id-or-cloned-volume',
            },
            name => {
                description => "Unique bootc container name.",
                type => 'string', maxLength => 64, optional => 1,
            },
            description => {
                description => "Free text description.",
                type => 'string', optional => 1, maxLength => 128,
            },
            onboot => {
                description => "Container will be started during node boot.",
                type => 'boolean', optional => 1, default => 0,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        my ($node, $vmid) = ($param->{node}, $param->{vmid});

        raise_param_exc({ vmid => "guest $vmid already exists" })
            if PVE::Cluster::get_vmlist()->{ids}->{$vmid};

        # resolve the template through the standard storage API
        my $storage_cfg = PVE::Storage::config();
        my $volid = $param->{archive};
        PVE::Storage::activate_storage($storage_cfg, ($volid =~ /^([^:]+):/)[0], $node);

        my $cmd = [$wrapper, 'create', $vmid, $volid];
        push @$cmd, '--name', $param->{name} if defined($param->{name});
        push @$cmd, '--description', $param->{description}
            if defined($param->{description});
        push @$cmd, '--onboot', $param->{onboot} ? 1 : 0
            if defined($param->{onboot});

        return $rpcenv->fork_worker(
            'bootccreate', $vmid, $authuser,
            sub { PVE::Tools::run_command($cmd, errmsg => "bootc create $vmid failed"); });
    },
});

__PACKAGE__->register_method({
    name => 'compose_publish',
    path => 'compose/{stack}',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    description => "Build, smoke-test and publish a compose stack as a seed"
        . " template (Portainer-style editor entry point; task UPID returned).",
    permissions => { check => ['perm', '/', ['VM.Allocate']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            stack => {
                description => "Stack name (template <stack>.tar.gz and image"
                    . " localhost/<stack>:latest derive from it).",
                type => 'string', pattern => '[a-zA-Z0-9][a-zA-Z0-9_.-]*',
                maxLength => 64,
            },
            compose => {
                description => "The docker-compose.yml content.",
                type => 'string', maxLength => 1024 * 1024,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        my ($node, $stack, $compose) =
            ($param->{node}, $param->{stack}, $param->{compose});

        # the compose source lands outside the deb tree, beside the other
        # recorded stacks; the wrapper hands it to pvect-ostree publish
        my $dir = '/var/lib/pvect-ostree/compose-ui';
        mkdir $dir;
        my $file = "$dir/$stack.yml";
        PVE::Tools::file_set_contents($file, $compose);

        return $rpcenv->fork_worker(
            'bootcpublish', $stack, $authuser,
            sub { PVE::Tools::run_command([$wrapper, 'publish', $file,
                '--name', $stack], errmsg => "bootc publish $stack failed"); });
    },
});

__PACKAGE__->register_method({
    name => 'compose_refresh',
    path => '{vmid}/compose-refresh',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    description => "Rebuild the guest from its recorded compose source"
        . " (pvect-ostree refresh; previous deployment kept for rollback).",
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
        my $authuser = $rpcenv->get_user();
        $rpcenv->{type} = 'priv'; # to start tasks in background
        my ($node, $vmid) = ($param->{node}, $param->{vmid});

        my $conf = PVE::Bootc::load_config($vmid, $node);
        die "guest $vmid has no recorded compose source\n" if !$conf->{compose};

        return $rpcenv->fork_worker(
            'bootcrefresh', $vmid, $authuser,
            sub { PVE::Tools::run_command([$wrapper, 'refresh', $vmid],
                errmsg => "bootc refresh $vmid failed"); });
    },
});

__PACKAGE__->register_method({
    name => 'list_templates',
    path => 'templates',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    permissions => { user => 'all' },
    description => "Published seed templates on the pvect-ostree storage.",
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'array' },
    code => sub {
        my ($param) = @_;

        # the wrapper owns the template metadata (stack, image, recorded
        # compose source, epoch); TSV keeps the parsing trivial
        my $templates_out = '';
        eval {
            PVE::Tools::run_command([$wrapper, 'templates'], outfunc => sub {
                $templates_out .= $_[0];
            }, errmsg => 'templates listing failed');
        };
        my $res = [];
        for my $line (split(/\n/, $templates_out // '')) {
            my ($archive, $stack, $imgref, $ctime, $compose) = split(/\t/, $line);
            next if !defined($archive) || $archive eq '';
            push @$res, {
                archive => $archive,
                stack => $stack // '',
                imgref => $imgref // '',
                ctime => ($ctime // 0) + 0,
                compose => $compose // '',
            };
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'template_read_compose',
    path => 'template/{stack}/compose',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/', ['VM.Allocate']] },
    description => "The recorded compose source of a published stack.",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            stack => {
                description => "Stack name.",
                type => 'string', pattern => '[a-zA-Z0-9][a-zA-Z0-9_.-]*',
                maxLength => 64,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $out = '';
        PVE::Tools::run_command([$wrapper, 'compose-read', $param->{stack}],
            outfunc => sub { $out .= $_[0] },
            errmsg => "compose-read $param->{stack} failed");
        return $out;
    },
});

1;
