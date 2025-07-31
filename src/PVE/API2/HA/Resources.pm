package PVE::API2::HA::Resources;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster;
use PVE::HA::Config;
use PVE::HA::Resources;
use HTTP::Status qw(:constants);
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

# fixme: use cfs_read_file

my $resource_type_enum = PVE::HA::Resources->lookup_types();

my $api_copy_config = sub {
    my ($cfg, $sid, $exclude_group_property) = @_;

    die "no such resource '$sid'\n" if !$cfg->{ids}->{$sid};

    my $scfg = dclone($cfg->{ids}->{$sid});
    $scfg->{sid} = $sid;
    $scfg->{digest} = $cfg->{digest};
    delete $scfg->{group} if $exclude_group_property;

    return $scfg;
};

sub check_service_state {
    my ($sid, $req_state) = @_;

    my $service_status = PVE::HA::Config::get_service_status($sid);
    if ($service_status->{managed} && $service_status->{state} eq 'error') {
        # service in error state, must get disabled before new state request
        # can be executed
        return if defined($req_state) && $req_state eq 'disabled';
        die "service '$sid' in error state, must be disabled and fixed first\n";
    }
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List HA resources.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            type => {
                description => "Only list resources of specific type",
                type => 'string',
                enum => $resource_type_enum,
                optional => 1,
            },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => { sid => { type => 'string' } },
        },
        links => [{ rel => 'child', href => "{sid}" }],
    },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::HA::Config::read_resources_config();
        my $groups = PVE::HA::Config::read_group_config();
        my $exclude_group_property = PVE::HA::Config::have_groups_been_migrated($groups);

        my $res = [];
        foreach my $sid (keys %{ $cfg->{ids} }) {
            my $scfg = &$api_copy_config($cfg, $sid, $exclude_group_property);
            next if $param->{type} && $param->{type} ne $scfg->{type};
            if ($scfg->{group} && !$groups->{ids}->{ $scfg->{group} }) {
                $scfg->{errors}->{group} = "group '$scfg->{group}' does not exist";
            }
            push @$res, $scfg;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'read',
    path => '{sid}',
    method => 'GET',
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    description => "Read resource configuration.",
    parameters => {
        additionalProperties => 0,
        properties => {
            sid => get_standard_option(
                'pve-ha-resource-or-vm-id',
                { completion => \&PVE::HA::Tools::complete_sid },
            ),
        },
    },
    returns => {
        type => 'object',
        properties => {
            sid => get_standard_option('pve-ha-resource-or-vm-id'),
            digest => {
                type => 'string',
                description => 'Can be used to prevent concurrent modifications.',
            },
            type => {
                type => 'string',
                description => 'The type of the resources.',
            },
            state => {
                type => 'string',
                enum => ['started', 'stopped', 'enabled', 'disabled', 'ignored'],
                optional => 1,
                description => "Requested resource state.",
            },
            failback => {
                description => "The HA resource is automatically migrated to"
                    . " the node with the highest priority according to their"
                    . " node affinity rule, if a node with a higher priority"
                    . " than the current node comes online.",
                type => 'boolean',
                optional => 1,
                default => 1,
            },
            group => get_standard_option('pve-ha-group-id', { optional => 1 }),
            max_restart => {
                description => "Maximal number of tries to restart the service on"
                    . " a node after its start failed.",
                type => 'integer',
                optional => 1,
            },
            max_relocate => {
                description => "Maximal number of service relocate tries when a"
                    . " service failes to start.",
                type => 'integer',
                optional => 1,
            },
            comment => {
                description => "Description.",
                type => 'string',
                optional => 1,
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::HA::Config::read_resources_config();
        my $exclude_group_property = PVE::HA::Config::have_groups_been_migrated();

        my $sid = PVE::HA::Config::parse_sid($param->{sid});

        return &$api_copy_config($cfg, $sid, $exclude_group_property);
    },
});

__PACKAGE__->register_method({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    permissions => {
        check => ['perm', '/', ['Sys.Console']],
    },
    description => "Create a new HA resource.",
    parameters => PVE::HA::Resources->createSchema(),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        # create /etc/pve/ha directory
        PVE::Cluster::check_cfs_quorum();
        mkdir("/etc/pve/ha");

        my ($sid, $type, $name) = PVE::HA::Config::parse_sid(extract_param($param, 'sid'));

        if (my $param_type = extract_param($param, 'type')) {
            # useless, but do it anyway
            die "types does not match\n" if $param_type ne $type;
        }

        my $plugin = PVE::HA::Resources->lookup($type);
        $plugin->verify_name($name);

        $plugin->exists($name);

        my $opts = $plugin->check_config($sid, $param, 1, 1);

        PVE::HA::Config::lock_ha_domain(
            sub {

                my $cfg = PVE::HA::Config::read_resources_config();

                if ($cfg->{ids}->{$sid}) {
                    die "resource ID '$sid' already defined\n";
                }

                $cfg->{ids}->{$sid} = $opts;

                PVE::HA::Config::write_resources_config($cfg);

            },
            "create resource failed",
        );

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'update',
    protected => 1,
    path => '{sid}',
    method => 'PUT',
    description => "Update resource configuration.",
    permissions => {
        check => ['perm', '/', ['Sys.Console']],
    },
    parameters => PVE::HA::Resources->updateSchema(),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');

        my ($sid, $type, $name) = PVE::HA::Config::parse_sid(extract_param($param, 'sid'));

        if (my $param_type = extract_param($param, 'type')) {
            # useless, but do it anyway
            die "types does not match\n" if $param_type ne $type;
        }

        if (my $group = $param->{group}) {
            my $group_cfg = PVE::HA::Config::read_group_config();

            die "HA group '$group' does not exist\n"
                if !$group_cfg->{ids}->{$group};
        }

        check_service_state($sid, $param->{state});

        PVE::HA::Config::update_resources_config($sid, $param, $delete, $digest);

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete',
    protected => 1,
    path => '{sid}',
    method => 'DELETE',
    description => "Delete resource configuration.",
    permissions => {
        check => ['perm', '/', ['Sys.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            sid => get_standard_option(
                'pve-ha-resource-or-vm-id',
                { completion => \&PVE::HA::Tools::complete_sid },
            ),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my ($sid, $type, $name) = PVE::HA::Config::parse_sid(extract_param($param, 'sid'));

        if (!PVE::HA::Config::service_is_configured($sid)) {
            die "cannot delete service '$sid', not HA managed!\n";
        }

        PVE::HA::Config::delete_service_from_config($sid);

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'migrate',
    protected => 1,
    path => '{sid}/migrate',
    method => 'POST',
    description => "Request resource migration (online) to another node.",
    permissions => {
        check => ['perm', '/', ['Sys.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            sid => get_standard_option(
                'pve-ha-resource-or-vm-id',
                { completion => \&PVE::HA::Tools::complete_sid },
            ),
            node => get_standard_option(
                'pve-node',
                {
                    completion => \&PVE::Cluster::complete_migration_target,
                    description => "Target node.",
                },
            ),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my ($sid, $type, $name) = PVE::HA::Config::parse_sid(extract_param($param, 'sid'));

        PVE::HA::Config::service_is_ha_managed($sid);

        check_service_state($sid);

        PVE::HA::Config::queue_crm_commands("migrate $sid $param->{node}");

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'relocate',
    protected => 1,
    path => '{sid}/relocate',
    method => 'POST',
    description =>
        "Request resource relocatzion to another node. This stops the service on the old node, and restarts it on the target node.",
    permissions => {
        check => ['perm', '/', ['Sys.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            sid => get_standard_option(
                'pve-ha-resource-or-vm-id',
                { completion => \&PVE::HA::Tools::complete_sid },
            ),
            node => get_standard_option(
                'pve-node',
                {
                    completion => \&PVE::Cluster::complete_migration_target,
                    description => "Target node.",
                },
            ),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my ($sid, $type, $name) = PVE::HA::Config::parse_sid(extract_param($param, 'sid'));

        PVE::HA::Config::service_is_ha_managed($sid);

        check_service_state($sid);

        PVE::HA::Config::queue_crm_commands("relocate $sid $param->{node}");

        return undef;
    },
});

1;
