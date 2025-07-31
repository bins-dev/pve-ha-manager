package PVE::API2::HA::Status;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file);
use PVE::DataCenterConfig;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::SafeSyslog;

use PVE::HA::Config;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

my $nodename = PVE::INotify::nodename();

my $timestamp_to_status = sub {
    my ($ctime, $timestamp) = @_;

    my $tdiff = $ctime - $timestamp;
    if ($tdiff > 30) {
        return "old timestamp - dead?";
    } elsif ($tdiff < -2) {
        return "detected time drift!";
    } else {
        return "active";
    }
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => { user => 'all' },
    description => "Directory index.",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        my ($param) = @_;

        my $result = [
            { name => 'current' }, { name => 'manager_status' },
        ];

        return $result;
    },
});

__PACKAGE__->register_method({
    name => 'status',
    path => 'current',
    method => 'GET',
    description => "Get HA manger status.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                id => {
                    description =>
                        "Status entry ID (quorum, master, lrm:<node>, service:<sid>).",
                    type => "string",
                },
                node => {
                    description => "Node associated to status entry.",
                    type => "string",
                },
                status => {
                    description => "Status of the entry (value depends on type).",
                    type => "string",
                },
                type => {
                    description => "Type of status entry.",
                    enum => ["quorum", "master", "lrm", "service"],
                },
                quorate => {
                    description => "For type 'quorum'. Whether the cluster is quorate or not.",
                    type => "boolean",
                    optional => 1,
                },
                timestamp => {
                    description =>
                        "For type 'lrm','master'. Timestamp of the status information.",
                    type => "integer",
                    optional => 1,
                },
                crm_state => {
                    description => "For type 'service'. Service state as seen by the CRM.",
                    type => "string",
                    optional => 1,
                },
                failback => {
                    description => "The HA resource is automatically migrated"
                        . " to the node with the highest priority according to"
                        . " their node affinity rule, if a node with a higher"
                        . " priority than the current node comes online.",
                    type => "boolean",
                    optional => 1,
                    default => 1,
                },
                max_relocate => {
                    description => "For type 'service'.",
                    type => "integer",
                    optional => 1,
                },
                max_restart => {
                    description => "For type 'service'.",
                    type => "integer",
                    optional => 1,
                },
                request_state => {
                    description => "For type 'service'. Requested service state.",
                    type => "string",
                    optional => 1,
                },
                sid => {
                    description => "For type 'service'. Service ID.",
                    type => "string",
                    optional => 1,
                },
                state => {
                    description => "For type 'service'. Verbose service state.",
                    type => "string",
                    optional => 1,
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $res = [];

        my $quorate = PVE::Cluster::check_cfs_quorum(1);
        push @$res,
            {
                id => 'quorum',
                type => 'quorum',
                node => $nodename,
                status => $quorate ? 'OK' : "No quorum on node '$nodename'!",
                quorate => $quorate ? 1 : 0,
            };

        my $status = PVE::HA::Config::read_manager_status();

        my $service_config = PVE::HA::Config::read_and_check_resources_config();

        my $ctime = time();

        if (defined($status->{master_node}) && defined($status->{timestamp})) {
            my $master = $status->{master_node};
            my $status_str = &$timestamp_to_status($ctime, $status->{timestamp});
            # mark crm idle if it has no service configured and is not active
            if ($quorate && $status_str ne 'active' && !keys %{$service_config}) {
                $status_str = 'idle';
            }

            my $extra_status = '';

            my $datacenter_config = eval { cfs_read_file('datacenter.cfg') } // {};
            if (my $crs = $datacenter_config->{crs}) {
                $extra_status = " - $crs->{ha} load CRS" if $crs->{ha} && $crs->{ha} ne 'basic';
            }
            my $time_str = localtime($status->{timestamp});
            my $status_text = "$master ($status_str, $time_str)$extra_status";
            push @$res,
                {
                    id => 'master',
                    type => 'master',
                    node => $master,
                    status => $status_text,
                    timestamp => $status->{timestamp},
                };
        }

        # compute active services for all nodes
        my $active_count = {};
        foreach my $sid (sort keys %{ $status->{service_status} }) {
            my $sd = $status->{service_status}->{$sid};
            next if !$sd->{node};
            $active_count->{ $sd->{node} } = 0 if !defined($active_count->{ $sd->{node} });
            my $req_state = $sd->{state};
            next if !defined($req_state);
            next if $req_state eq 'stopped';
            next if $req_state eq 'freeze';
            $active_count->{ $sd->{node} }++;
        }

        foreach my $node (sort keys %{ $status->{node_status} }) {
            my $lrm_status = PVE::HA::Config::read_lrm_status($node);
            my $id = "lrm:$node";
            if (!$lrm_status->{timestamp}) {
                push @$res,
                    {
                        id => $id,
                        type => 'lrm',
                        node => $node,
                        status => "$node (unable to read lrm status)",
                    };
            } else {
                my $status_str = &$timestamp_to_status($ctime, $lrm_status->{timestamp});
                my $lrm_mode = $lrm_status->{mode};

                if ($status_str eq 'active') {
                    $lrm_mode ||= 'active';
                    my $lrm_state = $lrm_status->{state} || 'unknown';
                    if ($lrm_mode ne 'active') {
                        $status_str = "$lrm_mode mode";
                    } else {
                        if ($lrm_state eq 'wait_for_agent_lock' && !$active_count->{$node}) {
                            $status_str = 'idle';
                        } else {
                            $status_str = $lrm_state;
                        }
                    }
                } elsif ($lrm_mode && $lrm_mode eq 'maintenance') {
                    $status_str = "$lrm_mode mode";
                }

                my $time_str = localtime($lrm_status->{timestamp});
                my $status_text = "$node ($status_str, $time_str)";
                push @$res,
                    {
                        id => $id,
                        type => 'lrm',
                        node => $node,
                        status => $status_text,
                        timestamp => $lrm_status->{timestamp},
                    };
            }
        }

        my $add_service = sub {
            my ($sid, $sc, $ss) = @_;

            my $data = { id => "service:$sid", type => 'service', sid => $sid };

            if ($ss) {
                $data->{node} = $ss->{node};
                $data->{crm_state} = $ss->{state};
            } elsif ($sc) {
                $data->{node} = $sc->{node};
            }
            my $node = $data->{node} // '---'; # to be save against manual tinkering

            $data->{state} = PVE::HA::Tools::get_verbose_service_state($ss, $sc);
            $data->{status} = "$sid ($node, $data->{state})"; # backward compat. and CLI

            # also return common resource attributes
            if (defined($sc)) {
                $data->{request_state} = $sc->{state};
                foreach my $key (qw(group max_restart max_relocate failback comment)) {
                    $data->{$key} = $sc->{$key} if defined($sc->{$key});
                }
            }

            push @$res, $data;
        };

        foreach my $sid (sort keys %{ $status->{service_status} }) {
            my $sc = $service_config->{$sid};
            my $ss = $status->{service_status}->{$sid};
            $add_service->($sid, $sc, $ss);
        }

        # show also service which aren't yet processed by the CRM
        foreach my $sid (sort keys %$service_config) {
            next if $status->{service_status}->{$sid};
            my $sc = $service_config->{$sid};
            $add_service->($sid, $sc);
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'manager_status',
    path => 'manager_status',
    method => 'GET',
    description => "Get full HA manger status, including LRM status.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $status = PVE::HA::Config::read_manager_status();

        my $data = { manager_status => $status };

        $data->{quorum} = {
            node => $nodename,
            quorate => PVE::Cluster::check_cfs_quorum(1),
        };

        foreach my $node (sort keys %{ $status->{node_status} }) {
            my $lrm_status = PVE::HA::Config::read_lrm_status($node);
            $data->{lrm_status}->{$node} = $lrm_status;
        }

        return $data;
    },
});

1;
