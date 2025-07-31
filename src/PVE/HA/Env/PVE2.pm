package PVE::HA::Env::PVE2;

use strict;
use warnings;
use POSIX qw(:errno_h :fcntl_h);
use IO::File;
use IO::Socket::UNIX;
use JSON;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::DataCenterConfig;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::Notify;

use PVE::HA::Tools ':exit_codes';
use PVE::HA::Env;
use PVE::HA::Config;
use PVE::HA::FenceConfig;
use PVE::HA::Resources;
use PVE::HA::Resources::PVEVM;
use PVE::HA::Resources::PVECT;
use PVE::HA::Rules;
use PVE::HA::Rules::NodeAffinity;

PVE::HA::Resources::PVEVM->register();
PVE::HA::Resources::PVECT->register();

PVE::HA::Resources->init();

PVE::HA::Rules::NodeAffinity->register();

PVE::HA::Rules->init(property_isolation => 1);

my $lockdir = "/etc/pve/priv/lock";

sub new {
    my ($this, $nodename) = @_;

    die "missing nodename" if !$nodename;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    $self->{nodename} = $nodename;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{nodename};
}

sub hardware {
    my ($self) = @_;

    die "hardware is for testing and simulation only";
}

sub read_manager_status {
    my ($self) = @_;

    return PVE::HA::Config::read_manager_status();
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    PVE::HA::Config::write_manager_status($status_obj);
}

sub read_lrm_status {
    my ($self, $node) = @_;

    $node = $self->{nodename} if !defined($node);

    return PVE::HA::Config::read_lrm_status($node);
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    my $node = $self->{nodename};

    PVE::HA::Config::write_lrm_status($node, $status_obj);
}

sub is_node_shutdown {
    my ($self) = @_;

    my $shutdown = 0;
    my $reboot = 0;

    my $code = sub {
        my $line = shift;

        # ensure we match the full unit name by matching /^JOB_ID UNIT /
        # see: man systemd.special
        $shutdown = 1 if ($line =~ m/^\d+\s+shutdown\.target\s+/);
        $reboot = 1 if ($line =~ m/^\d+\s+reboot\.target\s+/);
    };

    my $cmd = ['/bin/systemctl', '--full', 'list-jobs'];
    eval { PVE::Tools::run_command($cmd, outfunc => $code, noerr => 1); };

    return ($shutdown, $reboot);
}

sub queue_crm_commands {
    my ($self, $cmd) = @_;

    return PVE::HA::Config::queue_crm_commands($cmd);
}

sub any_pending_crm_command {
    my ($self) = @_;

    return PVE::HA::Config::any_pending_crm_command();
}

sub read_crm_commands {
    my ($self) = @_;

    return PVE::HA::Config::read_crm_commands();
}

sub read_service_config {
    my ($self) = @_;

    return PVE::HA::Config::read_and_check_resources_config();
}

sub update_service_config {
    my ($self, $sid, $param, $delete) = @_;

    return PVE::HA::Config::update_resources_config($sid, $param, $delete);
}

sub write_service_config {
    my ($self, $conf) = @_;

    return PVE::HA::Config::write_resources_config($conf);
}

sub parse_sid {
    my ($self, $sid) = @_;

    return PVE::HA::Config::parse_sid($sid);
}

sub read_fence_config {
    my ($self) = @_;

    return PVE::HA::Config::read_fence_config();
}

sub fencing_mode {
    my ($self) = @_;

    my $datacenterconfig = cfs_read_file('datacenter.cfg');

    return 'watchdog' if !$datacenterconfig->{fencing};

    return $datacenterconfig->{fencing};
}

sub exec_fence_agent {
    my ($self, $agent, $node, @param) = @_;

    # setup execution environment
    $ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

    my $cmd = "$agent " . PVE::HA::FenceConfig::gen_arg_str(@param);

    exec($cmd);
    exit -1;
}

# this is only allowed by the master to recover a _fenced_ service
sub steal_service {
    my ($self, $sid, $current_node, $new_node) = @_;

    my (undef, $type, $name) = PVE::HA::Config::parse_sid($sid);

    if (my $plugin = PVE::HA::Resources->lookup($type)) {
        my $old = $plugin->config_file($name, $current_node);
        my $new = $plugin->config_file($name, $new_node);
        rename($old, $new)
            || die "rename '$old' to '$new' failed - $!\n";
    } else {
        die "implement me";
    }

    # Necessary for (at least) static usage plugin to always be able to read service config from new
    # node right away.
    $self->cluster_state_update();
}

sub read_rules_config {
    my ($self) = @_;

    return PVE::HA::Config::read_and_check_rules_config();
}

sub write_rules_config {
    my ($self, $rules) = @_;

    PVE::HA::Config::write_rules_config($rules);
}

sub read_group_config {
    my ($self) = @_;

    return PVE::HA::Config::read_group_config();
}

sub delete_group_config {
    my ($self) = @_;

    PVE::HA::Config::delete_group_config();
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    my ($node_info, $quorate) = ({}, 0);

    my $nodename = $self->{nodename};

    $quorate = PVE::Cluster::check_cfs_quorum(1) || 0;

    my $members = PVE::Cluster::get_members();

    foreach my $node (keys %$members) {
        my $d = $members->{$node};
        $node_info->{$node}->{online} = $d->{online};
    }

    $node_info->{$nodename}->{online} = 1; # local node is always up

    return ($node_info, $quorate);
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    syslog($level, $msg);
}

sub send_notification {
    my ($self, $template_name, $template_data, $metadata_fields) = @_;

    eval { PVE::Notify::error($template_name, $template_data, $metadata_fields); };

    $self->log("warning", "could not notify: $@") if $@;
}

my $last_lock_status_hash = {};

sub get_pve_lock {
    my ($self, $lockid) = @_;

    my $got_lock = 0;

    my $filename = "$lockdir/$lockid";

    $last_lock_status_hash->{$lockid} //= { lock_time => 0, got_lock => 0 };
    my $last = $last_lock_status_hash->{$lockid};

    my $ctime = time();
    my $last_lock_time = $last->{lock_time} // 0;
    my $last_got_lock = $last->{got_lock};

    my $retry_timeout = 120; # hardcoded lock lifetime limit from pmxcfs

    eval {

        mkdir $lockdir;

        # pve cluster filesystem not online
        die "can't create '$lockdir' (pmxcfs not mounted?)\n" if !-d $lockdir;

        if (($ctime - $last_lock_time) < $retry_timeout) {
            # try cfs lock update request (utime)
            if (utime(0, $ctime, $filename)) {
                $got_lock = 1;
                return;
            }
            die "cfs lock update failed - $!\n";
        }

        if (mkdir $filename) {
            $got_lock = 1;
            return;
        }

        utime 0, 0, $filename; # cfs unlock request
        die "can't get cfs lock\n";
    };

    my $err = $@;

    #$self->log('err', $err) if $err; # for debugging

    $last->{got_lock} = $got_lock;
    $last->{lock_time} = $ctime if $got_lock;

    if (!!$got_lock != !!$last_got_lock) {
        if ($got_lock) {
            $self->log('info', "successfully acquired lock '$lockid'");
        } else {
            my $msg = "lost lock '$lockid";
            $msg .= " - $err" if $err;
            $self->log('err', $msg);
        }
    }

    return $got_lock;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->get_pve_lock("ha_manager_lock");
}

# release the cluster wide manager lock.
# when released another CRM may step up and get the lock, thus this should only
# get called when shutting down/deactivating the current master
sub release_ha_manager_lock {
    my ($self) = @_;

    return rmdir("$lockdir/ha_manager_lock");
}

sub get_ha_agent_lock {
    my ($self, $node) = @_;

    $node = $self->nodename() if !defined($node);

    return $self->get_pve_lock("ha_agent_${node}_lock");
}

# release the respective node agent lock.
# this should only get called if the nodes LRM gracefully shuts down with
# all services already cleanly stopped!
sub release_ha_agent_lock {
    my ($self) = @_;

    my $node = $self->nodename();

    return rmdir("$lockdir/ha_agent_${node}_lock");
}

sub quorate {
    my ($self) = @_;

    my $quorate = 0;
    eval { $quorate = PVE::Cluster::check_cfs_quorum(); };

    return $quorate;
}

sub get_time {
    my ($self) = @_;

    return time();
}

sub sleep {
    my ($self, $delay) = @_;

    CORE::sleep($delay);
}

sub sleep_until {
    my ($self, $end_time) = @_;

    for (;;) {
        my $cur_time = time();

        last if $cur_time >= $end_time;

        $self->sleep(1);
    }
}

sub loop_start_hook {
    my ($self) = @_;

    $self->{loop_start} = $self->get_time();

}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $self->get_time() - $self->{loop_start};

    warn "loop take too long ($delay seconds)\n" if $delay > 30;
}

sub cluster_state_update {
    my ($self) = @_;

    eval { PVE::Cluster::cfs_update(1) };
    if (my $err = $@) {
        $self->log('warn', "cluster file system update failed - $err");
        return 0;
    }

    return 1;
}

my $watchdog_fh;

sub watchdog_open {
    my ($self) = @_;

    die "watchdog already open\n" if defined($watchdog_fh);

    $watchdog_fh = IO::Socket::UNIX->new(
        Type => SOCK_STREAM(),
        Peer => "/run/watchdog-mux.sock",
    ) || die "unable to open watchdog socket - $!\n";

    $self->log('info', "watchdog active");
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    my $res = $watchdog_fh->syswrite("\0", 1);
    if (!defined($res)) {
        $self->log('err', "watchdog update failed - $!\n");
        return 0;
    }
    if ($res != 1) {
        $self->log('err', "watchdog update failed - write $res bytes\n");
        return 0;
    }

    return 1;
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    $watchdog_fh->syswrite("V", 1); # magic watchdog close
    if (!$watchdog_fh->close()) {
        $self->log('err', "watchdog close failed - $!");
    } else {
        $watchdog_fh = undef;
        $self->log('info', "watchdog closed (disabled)");
    }
}

sub after_fork {
    my ($self) = @_;

    # close inherited inotify FD from parent and reopen our own
    PVE::INotify::inotify_close();
    PVE::INotify::inotify_init();

    PVE::Cluster::cfs_update();
}

sub get_max_workers {
    my ($self) = @_;

    my $datacenterconfig = cfs_read_file('datacenter.cfg');

    return $datacenterconfig->{max_workers} || 4;
}

# return cluster wide enforced HA settings
sub get_datacenter_settings {
    my ($self) = @_;

    my $datacenterconfig = eval { cfs_read_file('datacenter.cfg') };
    $self->log('err', "unable to get HA settings from datacenter.cfg - $@") if $@;

    return {
        ha => $datacenterconfig->{ha} // {},
        crs => $datacenterconfig->{crs} // {},
    };
}

sub get_static_node_stats {
    my ($self) = @_;

    my $stats = PVE::Cluster::get_node_kv('static-info');
    for my $node (keys $stats->%*) {
        $stats->{$node} = eval { decode_json($stats->{$node}) };
        $self->log('err', "unable to decode static node info for '$node' - $@") if $@;
    }

    return $stats;
}

sub get_node_version {
    my ($self, $node) = @_;

    my $version_info = PVE::Cluster::get_node_kv('version-info', $node);
    return undef if !$version_info->{$node};

    my $node_version_info = eval { decode_json($version_info->{$node}) };

    return $node_version_info->{version};
}

1;
