package PVE::HA::Resources;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::SectionConfig;
use PVE::HA::Tools;

use base qw(PVE::SectionConfig);

my $defaultData = {
    propertyList => {
        type => { description => "Resource type.", optional => 1 },
        sid => get_standard_option(
            'pve-ha-resource-or-vm-id',
            { completion => \&PVE::HA::Tools::complete_sid },
        ),
        state => {
            type => 'string',
            enum => ['started', 'stopped', 'enabled', 'disabled', 'ignored'],
            optional => 1,
            default => 'started',
            description => "Requested resource state.",
            verbose_description => <<EODESC,
Requested resource state. The CRM reads this state and acts accordingly.
Please note that `enabled` is just an alias for `started`.

`started`;;

The CRM tries to start the resource. Service state is
set to `started` after successful start. On node failures, or when start
fails, it tries to recover the resource.  If everything fails, service
state it set to `error`.

`stopped`;;

The CRM tries to keep the resource in `stopped` state, but it
still tries to relocate the resources on node failures.

`disabled`;;

The CRM tries to put the resource in `stopped` state, but does not try
to relocate the resources on node failures. The main purpose of this
state is error recovery, because it is the only way to move a resource out
of the `error` state.

`ignored`;;

The resource gets removed from the manager status and so the CRM and the LRM do
not touch the resource anymore. All {pve} API calls affecting this resource
will be executed, directly bypassing the HA stack. CRM commands will be thrown
away while there source is in this state. The resource will not get relocated
on node failures.

EODESC
        },
        group => get_standard_option(
            'pve-ha-group-id',
            {
                optional => 1,
                completion => \&PVE::HA::Tools::complete_group,
            },
        ),
        failback => {
            description => "Automatically migrate HA resource to the node with"
                . " the highest priority according to their node affinity "
                . " rules, if a node with a higher priority than the current"
                . " node comes online.",
            type => 'boolean',
            optional => 1,
            default => 1,
        },
        max_restart => {
            description => "Maximal number of tries to restart the service on"
                . " a node after its start failed.",
            type => 'integer',
            optional => 1,
            default => 1,
            minimum => 0,
        },
        max_relocate => {
            description => "Maximal number of service relocate tries when a"
                . " service failes to start.",
            type => 'integer',
            optional => 1,
            default => 1,
            minimum => 0,
        },
        comment => {
            description => "Description.",
            type => 'string',
            optional => 1,
            maxLength => 4096,
        },
    },
};

sub verify_name {
    my ($class, $name) = @_;

    die "implement this in subclass";
}

sub private {
    return $defaultData;
}

sub format_section_header {
    my ($class, $type, $sectionId) = @_;

    my (undef, $name) = split(':', $sectionId, 2);

    return "$type: $name\n";
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $name) = (lc($1), $2);
        my $errmsg = undef; # set if you want to skip whole section
        eval {
            if (my $plugin = $defaultData->{plugins}->{$type}) {
                $plugin->verify_name($name);
            } else {
                die "no such resource type '$type'\n";
            }
        };
        $errmsg = $@ if $@;
        my $config = {}; # to return additional attributes
        return ($type, "$type:$name", $errmsg, $config);
    }
    return undef;
}

sub start {
    my ($class, $haenv, $id) = @_;

    die "implement in subclass";
}

sub shutdown {
    my ($class, $haenv, $id, $timeout) = @_;

    die "implement in subclass";
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    die "implement in subclass";
}

sub config_file {
    my ($class, $id, $nodename) = @_;

    die "implement in subclass";
}

sub exists {
    my ($class, $id, $noerr) = @_;

    die "implement in subclass";
}

sub check_running {
    my ($class, $haenv, $id) = @_;

    die "implement in subclass";
}

sub remove_locks {
    my ($self, $haenv, $id, $locks, $service_node) = @_;

    die "implement in subclass";
}

sub get_static_stats {
    my ($class, $haenv, $id, $service_node) = @_;

    die "implement in subclass";
}

# package PVE::HA::Resources::IPAddr;

# use strict;
# use warnings;
# use PVE::Tools qw($IPV4RE $IPV6RE);

# use base qw(PVE::HA::Resources);

# sub type {
#     return 'ipaddr';
# }

# sub verify_name {
#     my ($class, $name) = @_;

#     die "invalid IP address\n" if $name !~ m!^$IPV6RE|$IPV4RE$!;
# }

# sub options {
#     return {
# 	state => { optional => 1 },
# 	group => { optional => 1 },
# 	comment => { optional => 1 },
#     };
# }

1;
