#!/usr/bin/perl
# $Id$
# This program aims to change node state automatically when they are inaccesible or they become alive

use oar_iolib;
use oar_Judas qw(oar_debug oar_warn oar_error set_current_log_category);
use ping_checker qw(test_hosts);
use oar_conflib qw(init_conf dump_conf get_conf is_conf);
use Data::Dumper;
use strict;
use IO::Socket::INET;

# Log category
set_current_log_category('main');

oar_debug("[finaud] Finaud started\n");

oar_debug("[finaud] Check Alive and Suspected nodes\n");
my $base = iolib::connect();

my @node_list_tmp = iolib::get_finaud_nodes($base);
my $Occupied_nodes;
my $check_occupied_nodes;

# get in conf the options that tells if we have to check nodes
# that are running jobs.
init_conf($ENV{OARCONFFILE});
if (is_conf("CHECK_NODES_WITH_RUNNING_JOB")){
    $check_occupied_nodes = get_conf("CHECK_NODES_WITH_RUNNING_JOB");
}else {
    $check_occupied_nodes = 'no';
}
# if the value we got from conf is not yes or no, set it to default (no)
if ($Occupied_nodes ne 'yes' && $Occupied_nodes ne 'no'){
    $Occupied_nodes = 'no';
}

if ($check_occupied_nodes eq 'no'){
    $Occupied_nodes = iolib::get_current_assigned_nodes($base);
}

my %Nodes_hash;
foreach my $i (@node_list_tmp){
    if (($check_occupied_nodes eq 'no') && !defined($Occupied_nodes->{$i->{network_address}})){
        $Nodes_hash{$i->{network_address}} = $i;
    }
}

my @Nodes_to_check = keys(%Nodes_hash);
oar_debug("[finaud] Testing resource(s) on : @Nodes_to_check\n");

# Call the right program to test each nodes
my %bad_node_hash;
foreach my $i (test_hosts(@Nodes_to_check)){
    $bad_node_hash{$i} = 1;
}

#Make the decisions
my $return_value = 0;
foreach my $i (values(%Nodes_hash)){
    if (defined($bad_node_hash{$i->{network_address}}) and ($i->{state} eq "Alive")){
        iolib::set_node_nextState($base,$i->{network_address},"Suspected");
        iolib::update_node_nextFinaudDecision($base,$i->{network_address},"YES");
        $return_value = 1;
        oar_debug("[finaud] Set the next state of $i->{network_address} to Suspected\n");
    }elsif (!defined($bad_node_hash{$i->{network_address}}) and ($i->{state} eq "Suspected")){
        iolib::set_node_nextState($base,$i->{network_address},"Alive");
        iolib::update_node_nextFinaudDecision($base,$i->{network_address},"YES");
        $return_value = 1;
        oar_debug("[finaud] Set the next state of $i->{network_address} to Alive\n");
    }
}

iolib::disconnect($base);

oar_debug("[finaud] Finaud ended : $return_value\n");

exit($return_value);