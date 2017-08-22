#
# Copyright (c) 2011 Nathan Scott, 2015 Lukas Zapletal.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
use strict;
use warnings;
use YAML qw(LoadFile);
use PCP::PMDA;
use DBI;

use vars qw( $pmda $dbh $avg_indom %avg_idx );
my $os_user = 'postgres';
my $config = LoadFile('/etc/foreman/database.yml');
my $dbname = $config->{production}->{database};
my $database = "dbi:Pg:dbname=${dbname};host=localhost";
my %averages;

for my $file (  '/etc/pcpdbi.conf', # system defaults (lowest priority)
  pmda_config('PCP_PMDAS_DIR') . '/postgresql/postgresql.conf',
  './postgresql.conf' ) { # current directory (high priority)
  eval `cat $file` unless ! -f $file;
}

sub pmda_connection_setup
{
  if (!defined($dbh)) {
    $dbh = DBI->connect($database,
      $config->{production}->{username},
      $config->{production}->{password})
      or die "Couldn't connect to database";
  }

  %avg_idx = ();
  %averages = ();
  my $counter = 0;
  my $result = sql("select label, avg(extract(epoch from (ended_at - started_at))) as duration from foreman_tasks_tasks where ended_at > now() - interval '1 day' and (state != 'pending' and state != 'running') and (label != 'Actions::Candlepin::ListenOnCandlepinEvents' and label != 'Actions::Katello::EventQueue::Monitor') group by label order by duration desc");
  while (my @data = $result->fetchrow_array()) {
    my $label = $data[0];
    my $avg = $data[1];
    $avg_idx{$label} = $counter;
    $averages{$counter} = $avg;
    $counter += 1;
  }
  $pmda->replace_indom( $avg_indom, \%avg_idx);
}

sub sql {
  my $sth = $dbh->prepare(shift)
    or die "Couldn't prepare statement: " . $dbh->errstr;

  $sth->execute(@_)
    or die "Couldn't execute statement: " . $sth->errstr;
  return $sth;
}

sub pmda_fetch_callback
{
  my ($cluster, $item, $inst) = @_;
  if ($item == 0) {
    my $result = sql("select count(*) from foreman_tasks_tasks where state = ?", "running");
    my @data = $result->fetchrow_array();
    return ($data[0], 1)
  } elsif ($item == 1) {
    my $result = sql("select count(*) from foreman_tasks_tasks where state = ?", "pending");
    my @data = $result->fetchrow_array();
    return ($data[0], 1)
  } elsif ($item == 2) {
    return ($averages{$inst}, 1)
  }
  # returns array of value, status
  return (PM_ERR_PMID, 0);
}

my $cluster = 0;
$pmda = PCP::PMDA->new('foremantasks', 401);
$pmda->connect_pmcd;
$pmda->add_metric(pmda_pmid($cluster,0), PM_TYPE_U32, PM_INDOM_NULL, PM_SEM_INSTANT,
  pmda_units(0,0,0,0,0,0), 'foreman.tasks.running', '', '');
$pmda->add_metric(pmda_pmid($cluster,1), PM_TYPE_U32, PM_INDOM_NULL, PM_SEM_INSTANT,
  pmda_units(0,0,0,0,0,0), 'foreman.tasks.pending', '', '');
$avg_indom = $pmda->add_indom(0, {}, '', '');
$pmda->add_metric(pmda_pmid($cluster,2), PM_TYPE_FLOAT, $avg_indom, PM_SEM_INSTANT,
  pmda_units(0,1,0,0,PM_TIME_SEC,PM_COUNT_ONE), 'foreman.tasks.duration', '', '');

$pmda->set_fetch(\&pmda_connection_setup);
$pmda->set_fetch_callback(\&pmda_fetch_callback);

if (!defined($ENV{PCP_PERL_PMNS}) && !defined($ENV{PCP_PERL_DOMAIN})) {
  $pmda->log("Change to UID of user \"$os_user\"");
  $pmda->set_user($os_user);
}
$pmda->run;
