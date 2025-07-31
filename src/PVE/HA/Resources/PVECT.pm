package PVE::HA::Resources::PVECT;

use strict;
use warnings;

use PVE::Cluster;

use PVE::HA::Tools;

BEGIN {
    if (!$ENV{PVE_GENERATING_DOCS}) {
        require PVE::LXC;
        import PVE::LXC;
        require PVE::LXC::Config;
        import PVE::LXC::Config;
        require PVE::API2::LXC;
        import PVE::API2::LXC;
        require PVE::API2::LXC::Status;
        import PVE::API2::LXC::Status;
    }
}

use base qw(PVE::HA::Resources);

sub type {
    return 'ct';
}

sub verify_name {
    my ($class, $name) = @_;

    die "invalid VMID\n" if $name !~ m/^[1-9][0-9]+$/;
}

sub options {
    return {
        state => { optional => 1 },
        group => { optional => 1 },
        comment => { optional => 1 },
        failback => { optional => 1 },
        max_restart => { optional => 1 },
        max_relocate => { optional => 1 },
    };
}

sub config_file {
    my ($class, $vmid, $nodename) = @_;

    return PVE::LXC::Config->config_file($vmid, $nodename);
}

sub exists {
    my ($class, $vmid, $noerr) = @_;

    my $vmlist = PVE::Cluster::get_vmlist();

    if (!defined($vmlist->{ids}->{$vmid})) {
        die "resource 'ct:$vmid' does not exist in cluster\n" if !$noerr;
        return undef;
    } else {
        return 1;
    }
}

sub start {
    my ($class, $haenv, $id) = @_;

    my $nodename = $haenv->nodename();

    my $params = {
        node => $nodename,
        vmid => $id,
    };

    my $upid = PVE::API2::LXC::Status->vm_start($params);
    PVE::HA::Tools::upid_wait($upid, $haenv);
}

sub shutdown {
    my ($class, $haenv, $id, $timeout) = @_;

    my $nodename = $haenv->nodename();
    my $shutdown_timeout = $timeout // 60;

    my $upid;
    my $params = {
        node => $nodename,
        vmid => $id,
    };

    if ($shutdown_timeout) {
        $params->{timeout} = $shutdown_timeout;
        $upid = PVE::API2::LXC::Status->vm_shutdown($params);
    } else {
        $upid = PVE::API2::LXC::Status->vm_stop($params);
    }

    PVE::HA::Tools::upid_wait($upid, $haenv);
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my $nodename = $haenv->nodename();

    my $params = {
        node => $nodename,
        vmid => $id,
        target => $target,
        online => 0, # we cannot migrate CT (yet) online, only relocate
    };

    # always relocate container for now
    if ($class->check_running($haenv, $id)) {
        $class->shutdown($haenv, $id);
    }

    my $oldconfig = $class->config_file($id, $nodename);

    my $upid = PVE::API2::LXC->migrate_vm($params);
    PVE::HA::Tools::upid_wait($upid, $haenv);

    # check if vm really moved
    return !(-f $oldconfig);
}

sub check_running {
    my ($class, $haenv, $vmid) = @_;

    return PVE::LXC::check_running($vmid);
}

sub remove_locks {
    my ($self, $haenv, $id, $locks, $service_node) = @_;

    $service_node = $service_node || $haenv->nodename();

    my $conf = PVE::LXC::Config->load_config($id, $service_node);

    return undef if !defined($conf->{lock});

    foreach my $lock (@$locks) {
        if ($conf->{lock} eq $lock) {
            delete $conf->{lock};

            my $cfspath = PVE::LXC::Config->cfs_config_path($id, $service_node);
            PVE::Cluster::cfs_write_file($cfspath, $conf);

            return $lock;
        }
    }

    return undef;
}

sub get_static_stats {
    my ($class, $haenv, $id, $service_node) = @_;

    my $conf = PVE::LXC::Config->load_config($id, $service_node);

    return {
        maxcpu => PVE::LXC::Config->get_derived_property($conf, 'max-cpu'),
        maxmem => PVE::LXC::Config->get_derived_property($conf, 'max-memory'),
    };
}

1;
