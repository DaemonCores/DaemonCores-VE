package PVE::API2::Bootc::Stacks;

# Stack-level bootc API (variant A): publish a compose stack as a seed
# template, list the published templates, read a template's recorded compose
# source. Mounted beside the guest tree at nodes/{node}/bootc-stacks because
# PVE::RESTHandler refuses a fixed path item next to the {vmid} regex item at
# the same level (it would otherwise share the root of nodes/{node}/bootc).

use strict;
use warnings;

use PVE::Tools;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::RESTHandler);

my $wrapper = '/usr/share/pve-manager/dc/pvect-bootc';

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
