package PVE::HA::Env;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;

# abstract out the cluster environment for a single node

sub new {
    my ($this, $baseclass, $node, @args) = @_;

    my $class = ref($this) || $this;

    my $plug = $baseclass->new($node, @args);

    my $self = bless { plug => $plug }, $class;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{plug}->nodename();
}

sub hardware {
    my ($self) = @_;

    return $self->{plug}->hardware();
}

# manager status is stored on cluster, protected by ha_manager_lock
sub read_manager_status {
    my ($self) = @_;

    return $self->{plug}->read_manager_status();
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    return $self->{plug}->write_manager_status($status_obj);
}

# lrm status is written by LRM, protected by ha_agent_lock,
# but can be read by any node (CRM)

sub read_lrm_status {
    my ($self, $node) = @_;

    return $self->{plug}->read_lrm_status($node);
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    return $self->{plug}->write_lrm_status($status_obj);
}

# check if we do node shutdown
# we used this to decide if services should be stopped or freezed
sub is_node_shutdown {
    my ($self) = @_;

    return $self->{plug}->is_node_shutdown();
}

# implement a way to send commands to the CRM master
sub queue_crm_commands {
    my ($self, $cmd) = @_;

    return $self->{plug}->queue_crm_commands($cmd);
}

# returns true if any command is queued without altering/clearing the command queue
sub any_pending_crm_command {
    my ($self) = @_;

    return $self->{plug}->any_pending_crm_command();
}

sub read_crm_commands {
    my ($self) = @_;

    return $self->{plug}->read_crm_commands();
}

sub read_service_config {
    my ($self) = @_;

    return $self->{plug}->read_service_config();
}

sub update_service_config {
    my ($self, $sid, $param, $delete) = @_;

    return $self->{plug}->update_service_config($sid, $param, $delete);
}

sub write_service_config {
    my ($self, $conf) = @_;

    $self->{plug}->write_service_config($conf);
}

sub parse_sid {
    my ($self, $sid) = @_;

    return $self->{plug}->parse_sid($sid);
}

sub read_fence_config {
    my ($self) = @_;

    return $self->{plug}->read_fence_config();
}

sub fencing_mode {
    my ($self) = @_;

    return $self->{plug}->fencing_mode();
}

sub exec_fence_agent {
    my ($self, $agent, $node, @param) = @_;

    return $self->{plug}->exec_fence_agent($agent, $node, @param);
}

# this is normally only allowed by the master to recover a _fenced_ service
sub steal_service {
    my ($self, $sid, $current_node, $new_node) = @_;

    return $self->{plug}->steal_service($sid, $current_node, $new_node);
}

sub read_rules_config {
    my ($self) = @_;

    return $self->{plug}->read_rules_config();
}

sub write_rules_config {
    my ($self, $rules) = @_;

    $self->{plug}->write_rules_config($rules);
}

sub read_group_config {
    my ($self) = @_;

    return $self->{plug}->read_group_config();
}

sub delete_group_config {
    my ($self) = @_;

    $self->{plug}->delete_group_config();
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    return $self->{plug}->get_node_info();
}

sub log {
    my ($self, $level, @args) = @_;

    return $self->{plug}->log($level, @args);
}

sub send_notification {
    my ($self, $subject, $text, $properties) = @_;

    return $self->{plug}->send_notification($subject, $text, $properties);
}

# acquire a cluster wide manager lock
sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->{plug}->get_ha_manager_lock();
}

# release the cluster wide manager lock.
# when released another CRM may step up and get the lock, thus this should only
# get called when shutting down/deactivating the current master
sub release_ha_manager_lock {
    my ($self) = @_;

    return $self->{plug}->release_ha_manager_lock();
}

# acquire a cluster wide node agent lock
sub get_ha_agent_lock {
    my ($self, $node) = @_;

    return $self->{plug}->get_ha_agent_lock($node);
}

# release the respective node agent lock.
# this should only get called if the nodes LRM gracefully shuts down with
# all services already cleanly stopped!
sub release_ha_agent_lock {
    my ($self) = @_;

    return $self->{plug}->release_ha_agent_lock();
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    return $self->{plug}->quorate();
}

# return current time
# overwrite that if you want to simulate
sub get_time {
    my ($self) = @_;

    return $self->{plug}->get_time();
}

sub sleep {
    my ($self, $delay) = @_;

    return $self->{plug}->sleep($delay);
}

sub sleep_until {
    my ($self, $end_time) = @_;

    return $self->{plug}->sleep_until($end_time);
}

sub loop_start_hook {
    my ($self, @args) = @_;

    return $self->{plug}->loop_start_hook(@args);
}

sub loop_end_hook {
    my ($self, @args) = @_;

    return $self->{plug}->loop_end_hook(@args);
}

sub cluster_state_update {
    my ($self) = @_;

    return $self->{plug}->cluster_state_update();
}

sub watchdog_open {
    my ($self) = @_;

    # Note: when using /dev/watchdog, make sure perl does not close
    # the handle automatically at exit!!

    return $self->{plug}->watchdog_open();
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    return $self->{plug}->watchdog_update($wfh);
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    return $self->{plug}->watchdog_close($wfh);
}

sub after_fork {
    my ($self) = @_;

    return $self->{plug}->after_fork();
}

# maximal number of workers to fork,
# return 0 as a hack to support regression tests
sub get_max_workers {
    my ($self) = @_;

    return $self->{plug}->get_max_workers();
}

# return cluster wide enforced HA settings
sub get_datacenter_settings {
    my ($self) = @_;

    return $self->{plug}->get_datacenter_settings();
}

sub get_static_node_stats {
    my ($self) = @_;

    return $self->{plug}->get_static_node_stats();
}

sub get_node_version {
    my ($self, $node) = @_;

    return $self->{plug}->get_node_version($node);
}

1;
