#!/usr/local/bin/perl

use strict;
use integer;
use 5.006;

use Getopt::Long;
use Pod::Usage;
use POSIX qw(:sys_wait_h :time_h);
use Text::ParseWords;
use Text::Abbrev;
use File::Basename;
use IPC::Open3;
use Term::ANSIColor;
use IO::File;
use Carp;
#use Fatal qw(close); Pose trop de problème avec STDOUT< et STDERR
use Fcntl qw(:DEFAULT :flock);
use Data::Dumper;
use File::Spec;
use constant DEBUG => 0;

use DA::Lbd::Mail;

# Gestion des formats d'affichage
my @fmt_jobs;
my @fmt_jobs_header = qw(
    Started
    Ended
    Job
    Status
    State
    Command
);
my @fmt_session;
my @fmt_session_header = qw(
    Session
    State
    Status
);
# Les formats


# Globale
our %global=(
            success => 0,
            warning => 4,
            error   => 8,
            fatal   => 12,
            maxstep => 50,
);
# Affichage format HTML

sub html_table_header {
    print '<TABLE WIDTH="80%" BORDER="1" CELLSPACING="0" CELLPADDING="3">',"\n";
    print '<TR BGCOLOR="darkblue">',"\n";
    foreach my $title (@_) {
        print "<TH><FONT COLOR=\"white\">$title</FONT></TH>";
    }
    print '</TR>',"\n";
}

sub html_table {
    my $color=shift;
    print "<TR ALIGN=\"center\" BGCOLOR=\"$color\">";
    foreach my $value (@_) {
        print "<TD>$value</TD>";
    }
    print "</TR>\n";
}

sub html_table_end {
    print '</TABLE>',"\n";
}

sub csv_print {
    print join(";",@_),"\n";
}

# Format de date
sub log_date {
    return strftime('[%Y-%m-%d %H:%M:%S] ',localtime(time));
}

# Format de message
sub log_msg {
    my ($level,$progname,$pid)=@_;
    $progname ||= basename($0) unless $progname;
    $pid      ||= $$;

    my $line='['.$progname.' (PID '.$pid.')] ';
    my $blank1=length("warning")-length($level);
    my $blank2=30-length $line;

    return '['.uc($level).'] '.' 'x$blank1.$line.' 'x$blank2;
}

# Execution du job avec ajout d'un en tête au ligne
sub exec_job {
    my $job=shift;
    my ($pid);

    unless ($pid=open3('STDIN','PIPE',undef,@_)) {
        print &log_msg('error',$job),"Cannot fork '@_': $!\n";
        return 8;
    }
    print &log_msg('info',"$job>".$_[0],"$$>$pid"),$_ while (<PIPE>);
    close PIPE;
    waitpid $pid, 0;
    return WEXITSTATUS($?);
}

#
#--------------
# Lancement avec STEP
#--------------
#
sub exec_job_steps {
    my ($job_session,$job_list_ref,$job,$redo_job)=@_;
    my $error=0;

    my $maxstep = $global{maxstep} || 10;
    my $step       = $job_list_ref->{$job}->{STEP_INI};
    my $counter  = 0;
    my $rc           = 0;

    while ($step) {
        last if ($step eq "exit");

        unless (exists $job_list_ref->{$job}->{STEP}->{$step}) {
            print &log_msg('error'),"job($job/$step): step '$step' does not exist.\n";
            return 8;
        }

        my @cmd=shellwords($job_list_ref->{$job}->{STEP}->{$step}->{command});
        $counter++;

        if ($counter > $maxstep) {
            print &log_msg('error'),"job($job/$step): Ending step '@cmd'. STATUS=12. Max step $maxstep exceeded.\n";
            $error++;
            last;
        }

        # Gestion de la reprise dans 1 step
        if (exists $redo_job->{$job}) {
            if (exists $redo_job->{$job}->{STEP}->{$step}) {
                delete $redo_job->{$job};
            } else {
                $job_list_ref->{$job}->{STEP}->{$step}->{ignore}++;
            }
        }

        unless ($job_list_ref->{$job}->{STEP}->{$step}->{ignore}) {
		    print &log_msg('info'), "job($job/$step): Launching step '@cmd'.\n";
		    $rc = &exec_job("job($job/$step)",@cmd);
        } else {
		    print &log_msg('info'),"job($job/$step): Launching step 'Skipping step'.\n",
        }
        
        $ENV{LBD_JOB_RC} = $rc;

        if ($rc == $global{success})  {
            print &log_msg('info'),"job($job/$step): Ending step '@cmd' (PID $$). STATUS=$rc\n";
            $step=$job_list_ref->{$job}->{STEP}->{$step}->{success};
        } else {
            print &log_msg('info'),"REDOSTEP=$job_session=$job=$step\n";

            if ($rc == $global{warning}) {
                print &log_msg("warning"),"job($job/$step): Ending step '@cmd' (PID $$). STATUS=$rc\n";
                $step=$job_list_ref->{$job}->{STEP}->{$step}->{warning};
            } elsif ($rc == $global{error}) {
                print &log_msg('error'),"job($job/$step): Ending step '@cmd' (PID $$). STATUS=$rc\n";
                $step=$job_list_ref->{$job}->{STEP}->{$step}->{error};
            } elsif ($rc == $global{fatal}) {
                print &log_msg("fatal"),"job($job/$step): Ending step '@cmd' (PID $$). STATUS=$rc\n";
                $step=$job_list_ref->{$job}->{STEP}->{$step}->{fatal};
            } else {
                print &log_msg('error'),"job($job/$step): Ending step '@cmd' (PID $$). STATUS=$rc\n";
                $step=$job_list_ref->{$job}->{STEP}->{$step}->{error};
            }
        }
    }

    return $rc;
}

sub parse_redolog {
    my ($file,$session)=@_;
    $session=quotemeta($session);
    local $_;
    my $redo;

    open FILE, "<$file" or croak "tsmjobmonitor: Error - Cannot open file '$file': $!\n";
    while (<FILE>) {
        chomp;

        my ($job, $step);

        if (($job) = (m/REDO=$session=(\S+)/) ) {
            $redo->{$job}->{STATUS}++;
            next;
        }

        if (($job,$step) = (m/REDOSTEP=$session=([^=]+)=(\S+)/) ) {
            $redo->{$job}->{STEP}->{$step}++;
            next;
        }
    }
    close FILE;

    while (my ($key,$value) = each(%{$redo})) {
        delete $redo->{$key} unless (exists $redo->{$key}->{STATUS});
    }

    undef $redo unless (keys(%{$redo}));

    return ($redo);
}

# Lecture de l'entrée standard
sub read_stdout {
    my $log=shift;

    my $fh=\*STDOUT;
    if ($log) {
        $fh=IO::File->new($log,"a") or die &log_date(),&log_msg('error'),"Cannot open file '$log': $!\n";
        $fh->autoflush(1);
        # Assure qu'un seul process utilise le fichier
        flock($fh,LOCK_EX);
    }

    while (<STDIN>) {
        if (m/^\[[A-Z]+\]/) {
            print $fh &log_date(),$_;
        } else {
            print $fh &log_date(),&log_msg("warning"),"Catch kid error message: ",$_,"\n";
        }
    }

    if ($log) {
        flock($fh,LOCK_UN);
        $fh->close();
    }

    return 0;
}

sub analyse_log {
    my ($file)=@_;

    my $array_session=[];
    my $hash_session={};

    my ($current_session);
    
    my $regexp_date = qr/\d\d\d\d[- ](\d\d)[- ](\d\d)[- :](\d\d):(\d\d).*/;
    
    open FILE, '<', $file or die "tsmjobmonitor:analyse: [error] Cannot open file '$file': $!\n";
    while (<FILE>) {
        chomp;

        # Enregistrement de la session
        if (my ($start, $s) = (m/^\[([^\]]+)\].*Starting session ([-:\d]+)/)) {
            $current_session=$s;
            push(@{$array_session},$current_session);
            $hash_session->{$current_session}->{STATE}  = 'Running';
            $hash_session->{$current_session}->{STATUS} = '-';
            $hash_session->{$current_session}->{START}  = $start;
            $hash_session->{$current_session}->{ENDED}  = '-';

            next;
        }

        # Enregistrement Job
        if (my ($begintime, $job, $command) = (m/\[([^\]]+)\].*job\(([^\)]+)\): Launching [^']*\'([^\']+)\'/)) {
            $hash_session->{$current_session}->{JOB}->{$job}->{STATE}   = 'Running';
            $hash_session->{$current_session}->{JOB}->{$job}->{COMMAND} = $command;
            $hash_session->{$current_session}->{JOB}->{$job}->{STATUS}  = '-';
            $hash_session->{$current_session}->{JOB}->{$job}->{BEGIN}   = $begintime;
            
            DEBUG && warn "DEBUG: session=$current_session; job=$job; begintime=$begintime\n";
            my $res = $begintime =~ s/$regexp_date/$2\/$1 $3:$4/;
            
            DEBUG && warn "DEBUG: map_time '$begintime' catch '$res', 1=$1; 2=$2; 3=$3; 4=$4; !!$regexp_date!!\n";
            
            $hash_session->{$current_session}->{JOB}->{$job}->{STARTED} = $begintime;
            next;
        }

        # Fin job
        if (my ($endtime, $job, $status) = (m/\[([^\]]+)\].*job\(([^\)]+)\): Ending .*STATUS=(\d+)/)) {
            $status=($status)?("Error=$status"):("Success");
            $hash_session->{$current_session}->{JOB}->{$job}->{STATE}   = 'Completed';
            $hash_session->{$current_session}->{JOB}->{$job}->{STATUS}  = $status;
            $hash_session->{$current_session}->{JOB}->{$job}->{END}     = $endtime;
            $endtime =~ s/$regexp_date/$2\/$1 $3:$4/;
            $hash_session->{$current_session}->{JOB}->{$job}->{ENDED}   = $endtime;
            next;
        }

        # Fin session
        if (my ($end, $s, $status) = (m/^\[([^\]]+)\].*Ending session ([-:\d]+).*STATUS=(\d+)/)) {
            $hash_session->{$s}->{STATE}    = 'Completed';
            $status=($status)?("Error=$status"):("Success");
            $hash_session->{$s}->{STATUS}   = $status;
            $hash_session->{$s}->{ENDED}    = $end;
            next;
        }
    }
    close FILE;

    return ($array_session, $hash_session);
}

# Lit un fichier compliqué format Apache pour le futur, pour le moment prend
# une liste de job
sub parse_job_list {
#
# Structure:
#-----------
#
# struct JOB {
#        nom      => Généré automatiquement si absent
#        COMMAND  => commande ou _LAUNCH_STEP_
#        STEP_INI => step de départ
#        STEP     => liste de steps
#        class    => classification d'un job (pour plus tard pour ordonancer différencer des jobs du même
#                    fichier
#}
#
# struct STEP {
#        nom      => généré automatiquement si absent
#        command  => command
#        success  => step en cas de succes (par défaut le suivant dans l'ordre)
#        warning  => idem + par défaut pseudo step exit
#        fatal    => idem
#        ignore   => yes (si on veut sauter ce step)
#}
#
#struct global {
#       maxstep => nombre maximum de step
#       error   => code d'erreur
#       success => idem
#       warning => idem
#       fatal   => idem
#}
    my ($file, $verbose) = @_;
    my %fields           = abbrev(
        qw(class error warning success fatal maxstep command ignore priority)
    );
    my ($job,$job_list_ref,$step_id_nb,$step,$step_before);
    my $job_id_nb = 1;


    open FILE, "<$file" or croak "tsmjobmonitor: Error - Cannot open file '$file': $!\n";
    LINE: while (<FILE>) {
        # Ligne vide et commentaire
        next LINE if (m/^#/ or m/^\s*$/);

        # Commentaire de fin de ligne
        s/(?<!\\)#.*//;

        # Blanc à la fin + \n
        s/\s*$//;

        # Evaluation des variables d'environnement
        s/(?<!\\)\$(\w+)/$ENV{$1}/eg;
        s/\\\$/\$/g;

        DEBUG && warn "DEBUG:config_line: $_\n";

        # Définition à la mode Apache
        if (m/<(?i)job(?-i)\s*(\S*)>/ ... m/<\/(?i)job(?-i)[^>]*>/) {
            my $job_id=$1;

            if (m/<(?i)job(?-i)/) {
                unless ($job_id) {
                    $job=$job_id_nb;
                    $job_id_nb++;
                } else {
                    $job=$job_id;
                }

                # Remise à zéro des steps pour un process
                $step=undef;
                $step_id_nb=1;

                next LINE;
            }

            # Enregistrement de STEP
            if (m/<(?i)step(?-i)\s*(\S*)>/ ... m/<\/(?i)step(?-i)[^>]*>/) {
                my $step_id=$1;

                if (m/<(?i)step(?-i)/) {
                    # Sauvegarde du step précédent
                    $step_before=$step;

                    # Calcul du step nouveau
                    unless ($step_id) {
                        $step=$step_id_nb;
                        $step_id_nb++;
                    } else {
                        $step=$step_id;
                    }

                    # Mise en place séquentiel simple s'il le faut

                    if ($step_before && ! exists $job_list_ref->{$job}->{STEP}->{$step_before}->{command}) {
                        warn  "tsmjobmonitor: [warning] Invalid step job($job/$step_before). Discarding...\n";
                        $job_list_ref->{$job}->{STEP_INI}=$step if ($job_list_ref->{$job}->{STEP_INI} eq "$step_before");
                        delete $job_list_ref->{$job}->{STEP}->{$step_before};
                    } elsif($step_before) {
                        $job_list_ref->{$job}->{STEP}->{$step_before}->{success}=$step unless (exists $job_list_ref->{$job}->{STEP}->{$step_before}->{success});
                    }

                    # Enregistrement du step de départ
                    $job_list_ref->{$job}->{STEP_INI}=$step unless (exists $job_list_ref->{$job}->{STEP_INI});

                    # Lanceur de step
                    $job_list_ref->{$job}->{COMMAND}='_LAUNCH_STEP_';
                    next LINE;
                }

                if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/) {
                    my ($field,$value)=(lc($1),$2);

                    if (exists $fields{$field}) {
                        print "tsmjobmonitor: [info]  Registering job($job/$step) step option ",$fields{$field}," = '$value'.\n" if $verbose;
                        $job_list_ref->{$job}->{STEP}->{$step}->{$fields{$field}}=$value;
                    } else {
                       warn "tsmjobmonitor: [warning] Invalid field '$field'. Ignoring...\n";
                    }
                }

                next LINE;
            }

            # Enregistrement de paramètre globaux
            if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/) {
                my ($field,$value)=($1,$2);

                if (exists $fields{lc($field)}) {
                    if ($fields{lc($field)} eq 'command') {
                        $job_list_ref->{$job}->{COMMAND}=$value;
                        print "tsmjobmonitor: [info]  Registering job($job) job command '$value'.\n" if $verbose;
                    } else {
                        print "tsmjobmonitor: [info]  Registering job($job) job option ",$fields{lc($field)}," = '$value'.\n" if $verbose;
                        $job_list_ref->{$job}->{OPTION}->{$fields{lc($field)}}=$value;
                    }
                } else {
                    warn "tsmjobmonitor: [warning] Invalid field '$field'. Ignoring...\n";
                }
            }

            next LINE;
        }

        DEBUG && warn "DEBUG:config_line: no apache job: $_\n";

        if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/ or m/^\s*(\w+)/) {
            my ($field, $value) = ($1, $2);

            if (exists $fields{lc($field)}) {
                print "tsmjobmonitor: [info]  Registering global option ",$fields{lc($field)}," = '$value'.\n" if $verbose;
                $global{$fields{$field}}=$value;
                next LINE;
            }
        }
        # Job tout simple, pas à réfléchir
        s/^\s*//;
        print "tsmjobmonitor: [info]  Registering job($job_id_nb) = '$_'.\n" if $verbose;
        $job_list_ref->{$job_id_nb++}->{COMMAND}=$_;
    }
    close FILE;
    
    foreach my $global (keys %global) {
		$global{$global{$global}} = $global;
   }

    DEBUG && warn "DEBUG: ", Dumper($job_list_ref), "\n";
    return $job_list_ref;
}

sub format_log {
    my ($log, $job_list_ref, $opt_session, $long, $jobs_list_ref, $csv, $Html) = @_;

    my ($array_session, $hash_session) = analyse_log($log);

    $opt_session = ($opt_session) ? ($opt_session) : ($array_session->[-1]);

    DEBUG && warn "DEBUG: get session '$opt_session'.\n";

    die "tsmjobmonitor: [error] Session number '$opt_session' does not exist in file '$log'.\n" unless exists $hash_session->{$opt_session};

    SWITCH: {
        $csv && do {
            csv_print(@fmt_jobs_header);
            last SWITCH;
        };
        $Html && do {
            html_table_header(@fmt_jobs_header);
            last SWITCH;
        };

        $~='FMT_JOBS_HEADER';
        write;
        $~ = ($long) ? ('FMT_JOBS_LONG') : ('FMT_JOBS_SHORT');
    }

    # Liste de recherche des jobs
    my @job_list;
    if ($job_list_ref) {
        @job_list = @{$jobs_list_ref};
    } else {
        @job_list = sort {
                        my $ac = $hash_session->{$opt_session}->{JOB}->{$a}->{STATUS};
                        my $bc = $hash_session->{$opt_session}->{JOB}->{$b}->{STATUS};
                        $ac =~ s/[^\d]+//;
                        $ac ||= 0;
                        $bc =~ s/[^\d]+//;
                        $bc ||= 0;
                        if ($ac == $bc) {
                            my $a_end = $hash_session->{$opt_session}->{JOB}->{$a}->{END};
                            my $b_end = $hash_session->{$opt_session}->{JOB}->{$b}->{END};
                            if ($a_end eq $b_end) {
                                return ($hash_session->{$opt_session}->{JOB}->{$a}->{BEGIN} cmp $hash_session->{$opt_session}->{JOB}->{$b}->{BEGIN});
                            }
                            return ($b_end cmp $a_end);
                        }
                        return ($bc <=> $ac);
                       } keys(%{$hash_session->{$opt_session}->{JOB}});
    }

    DEBUG && warn "DEBUG: job list", Dumper(\@job_list);

    foreach my $job (@job_list) {
        if (exists $hash_session->{$opt_session}->{JOB}->{$job}) {
            @fmt_jobs=($hash_session->{$opt_session}->{JOB}->{$job}->{STARTED},
                       $hash_session->{$opt_session}->{JOB}->{$job}->{ENDED},
                       $job,
                       $hash_session->{$opt_session}->{JOB}->{$job}->{STATUS},
                       $hash_session->{$opt_session}->{JOB}->{$job}->{STATE},
                       $hash_session->{$opt_session}->{JOB}->{$job}->{'COMMAND'},
                       );
        } elsif ($job_list_ref) {
            @fmt_jobs=($opt_session, $job, '-', 'Waiting', $job_list_ref->{$job}->{'COMMAND'});
        }

        if ($csv) {
            csv_print(@fmt_jobs);
            next;
        }

        my %colors_text=(
                    'Success' => 'GREEN',
                    'Warning' => 'MAGENTA',
                    'Error'   => 'BLUE',
                    'Running' => 'YELLOW',
                    'Fatal'   => 'RED',
                    );
        my %colors_html=(
                    'Success' => 'lightgreen',
                    'Warning' => 'orange',
                    'Error'   => 'salmon',
                    'Running' => 'lightyellow',
                    'Fatal'   => 'red',
                    );

        my $status = 'Running';
           $status = 'Success' if ($fmt_jobs[3] =~ m/Success/);
        if (my ($rc) = ($fmt_jobs[3] =~ m/Error=(\d+)/)) {
            $status= ($rc == $global{warning})?
                                               ('Warning'):
                     ($rc==$global{error})?
                                               ('Error'):
                                               ('Fatal');
        }

        if ($Html) {
            html_table($colors_html{$status}, @fmt_jobs);
        } else {
            if (-t STDOUT) {
                print color($colors_text{$status});
            }
            write;
            if (-t STDOUT) {
                print color('RESET');
            }
        }
    }

    html_table_end() if $Html;
}
#
#----------
# Main
#----------
#

# Variables importantes
my $redo_job;

# Traitement des options

# Gestion des options
my (
    $analyse,
    $csv,
    $file,
    $help,
    $Html,
    @job,
    $log,
    $long,
    $max_process,
    $redo,
    $opt_session,
    $verbose,
    $window_mn,
    $waits,
    $mail_file,
);

# Initialisation de valeur

$window_mn   = 0;
$waits       = 0;
$max_process = 255;
Getopt::Long::Configure('no_ignore_case');
GetOptions(
            'analyse:s'    => \$analyse,
            'csv'          => \$csv,
            'file=s'       => \$file,
            'help'         => \$help,
            'Html'         => \$Html,
            'job=s'        => \@job,
            'log=s'        => \$log,
            'Long'         => \$long,
            'maxprocess=i' => \$max_process,
            'redo:s'       => \$redo,
            'session:s'    => \$opt_session,
            'verbose'      => \$verbose,
            'window=i'     => \$window_mn,
            'wait=s'       => \$waits,
            'mailfile'     => \$mail_file,
          ) or pod2usage(-message => 'Bad options.');

DEBUG && warn "DEBUG: mode\n";
pod2usage(
    -verbose => 1,
    -exitval => 4,
) if ($help);

# Lecture du fichier de job
my ($job_list_ref, @jobs_list);

if ($file) {
    $job_list_ref = parse_job_list($file, $verbose);
    @jobs_list    = keys(%{$job_list_ref});
}

# Lecture à partir de la ligne de commande
my $job_id_nb=0;
$job_list_ref->{$job_id_nb++}->{COMMAND}=$_ foreach (@job);

# Début des actions

# Analyse de la log
if (defined $analyse) {
    DEBUG && warn "DEBUG: analyse\n";

    pod2usage(-message => 'Need log file') unless $log;
    format_log($log, $job_list_ref, $opt_session, $long, \@jobs_list, $csv, $Html);

    exit(0);

} elsif (defined $redo) {
    # Mode redo
    my $redo_file = ($redo) ? ($redo) : ($log);

    pod2usage(-message => 'Need redo file.') unless -f $redo_file;
    print "Use redo log: $redo_file\n";
    my ($array_session, $hash_session) = analyse_log($redo_file);
    $opt_session=($opt_session)?($opt_session):($array_session->[-1]);
    #use Data::Dumper;
    #print Dumper($hash_session);
    print "Use session: $opt_session\n";
    pod2usage(-message => 'Need session number') unless exists $hash_session->{$opt_session};

    $redo_job=&parse_redolog($redo_file,$opt_session);
    die "tsmjobmonitor: [warning] No step to replay with log file '$redo_file' for session '$opt_session'.\n" unless $redo_job;
} elsif (defined $opt_session) {
    pod2usage(-message => 'Need log file') unless $log;
    my ($array_session, $hash_session)=analyse_log($log);

    SWITCH: {
       $Html && do {
            html_table_header(@fmt_session_header, "Start Time", "End Time");
            last SWITCH;
        };
        $csv && do {
            csv_print(@fmt_session_header, "Start Time", "End Time");
            last SWITCH;
        };
        $~ = 'FMT_SESSION_HEADER';
        write;
        $~ = 'FMT_SESSION';
    }

    foreach my $s (@{$array_session}) {
        @fmt_session = ($s, $hash_session->{$s}->{STATE}, $hash_session->{$s}->{STATUS});
        SWITCH: {
            $Html && do {
                my $color='lightyellow';
                $color = 'lightgreen'  if ($fmt_session[2] =~ m/Success/);
                $color = 'lightsalmon' if ($fmt_session[2] =~ m/Error/);
                html_table($color,@fmt_session, $hash_session->{$s}->{START}, $hash_session->{$s}->{ENDED});
                last SWITCH;
            };
            $csv && do {
                csv_print(@fmt_session, $hash_session->{$s}->{START}, $hash_session->{$s}->{ENDED});
                last SWITCH;
            };
            write;
        }
    }

    html_table_end() if $Html;

    exit(0);
}

#
#-----------
# Lancement des jobs
#-----------
#

# Vérification et initialisation
pod2usage({
    -message => 'No sufficient argument.',
    -exitval => 2,
}) unless ($job_list_ref);

# Calcul du délai d'attente entre chaque lancement
my $sleep     = int($window_mn*60/scalar(@jobs_list));
$sleep        = $waits if $waits; # l'emporte sur $window_mn

# Test du lock pour ne pas être bloquant (mode abandon)
if ($log) {
    my $fh_log=IO::File->new($log,"a") or die "tsmjobmonitor: Error - Cannot test lock: $!\n";
    my $lock=flock($fh_log,LOCK_EX | LOCK_NB);
    flock($fh_log,LOCK_UN) if $lock;
    $fh_log->close();
    die "tsmjobmonitor: Error - An other process use your file log '$log'\n" unless ($lock);
}


# On flush les entrées / sorties pour tout le programme
select STDERR ; $|=1;
select STDOUT ; $|=1;

#
#------------
# Process 1: Lit l'entrée Standard des process pere et fils
#------------
#
unless (my $pid=open STDOUT, '|-') {
    if (defined $pid) {
        # c'est parti
        exit &read_stdout($log);
    } else {
        # tant pis
        die &log_date(),&log_msg('error'),"Cannot fork to read STDOUT: $!\n";
    }
}

#
#-------------
# Process 2: redirige STDERR => STDOUT
#-------------
#
open STDERR, '>&=STDOUT';

#
#-------------
# Process 3: Démarrage du père ordonnancant tout le monde
#-------------
#

# Creation de la session
my $job_session = strftime("%y-%m-%d:%H:%M:%S:$$",localtime(time()));
print &log_msg('info'), "Starting session $job_session.\n";

# Lancement jobs
my %kids;

# Préparation de la mécanique multiprocess
my @jobs_runqueue = sort {
    $job_list_ref->{$b}->{OPTION}->{priority} <=> $job_list_ref->{$a}->{OPTION}->{priority};
} @jobs_list;

DEBUG && warn "DEBUG: ", Dumper(\@jobs_runqueue);

my %jobs_to_wait  = map { $_ => 1 } @jobs_runqueue;
my (%jobs_runqueue, %jobs_redo);
my $jobs_in_error = 0;

# C'est parti
JOB_LOOP: while (keys %jobs_to_wait) {
    # Encore des jobs dans la queue ?
    if (@jobs_runqueue) {
        my $current_job = shift @jobs_runqueue;

        # Ne reprend que les jobs marqués, cas REDO
        if (
            $redo_job                                   and
            ! exists $redo_job->{$current_job}->{STATUS}

        ) {
            delete $jobs_to_wait{$current_job};  # Libère un process de la file total
            print &log_msg('info'), "job($current_job): Launching 'Skipping job'.\n",
                     &log_msg('info'), "job($current_job): Ending 'Skipping job' STATUS=0.\n";
            next JOB_LOOP;
        }

        # Construction du job avec les arguments
        my $command = $job_list_ref->{$current_job}->{COMMAND};
        my @cmd     = shellwords($command);

        # Compteur de job
        if ($sleep) {
            print &log_msg('info'),"job($current_job): Sleeping for '",$sleep,"'s before launching '@cmd'.\n";
            # Patiente avant, limite le nombre de fork
            sleep $sleep;
        }

        # On cré le fils
        my $pid = fork();
        unless (defined $pid) {
            print &log_msg('error'), "job($current_job): Ending 'Cannot fork' STATUS=12: $!\n";
        }

        # On est dans le fils
        if ($pid == 0) {
            # On exécute avec les bons arguments
            print &log_msg('info'), "job($current_job): Launching '@cmd'.\n";
            if ($command eq '_LAUNCH_STEP_') {
                exit &exec_job_steps(
                    $job_session,
                    $job_list_ref,
                    $current_job,
                    $redo_job,
                );
            } else {
                exit &exec_job(
                    "job($current_job)",
                    @cmd,
                );
            }
        }

        # C'est le père, on enregistre le pid du job courant
        $jobs_runqueue{$pid} = $current_job;

        # On manage la file pour savoir si on relance
        # un job ou si on passe en wait des fils
        my $size_runqueue    = keys %jobs_runqueue;
        DEBUG && warn "DEBUG: runqueue = $size_runqueue / $max_process\n";
        next JOB_LOOP if ($size_runqueue < $max_process);
    }

    DEBUG && warn "DEBUG: waiting...\n";
    # Attente de la fin d'un fils + son code retour
    my $job_pid  = waitpid(-1,0);
    my $job_rc   = $?;

    # Ne sort pas si c'est un Ctrl-Z
    next JOB_LOOP unless (WIFEXITED($job_rc));

    # On récupere le code retour
    $job_rc        = WEXITSTATUS($job_rc);

    # Un cas impossible en théorie mais on ne sait jamais !
    next JOB_LOOP unless (exists $jobs_runqueue{$job_pid});

    # On depiote la pile des jobs pour trouver le process
    my $job_name = $jobs_runqueue{$job_pid};
    my $level    = 'info';
    if ($job_rc) {
        $level = 'error';

        # Increment le compteur de nombre de job en erreur
        $jobs_in_error++;

        # On le stack dans les piles des jobs en redo
        $jobs_redo{$job_name}++;
    }

    print &log_msg($level),
          'job(', "$job_name): Ending '",
          $job_list_ref->{$job_name}->{COMMAND},
          "' (PID $job_pid). STATUS=$job_rc\n";

    # On dépile la liste des jobs en runqueue (libere de la place mémoire)
    delete $jobs_runqueue{$job_pid};
    # On enleve de la liste des jobs à attendre
    delete $jobs_to_wait{$job_name};
}

# Préparation d'un reprise éventuelle
print &log_msg('info'), "REDO=$job_session=$_\n" foreach (keys(%jobs_redo));

# Fin de session
print &log_msg('info'),
      "Ending session $job_session. STATUS=$jobs_in_error ($jobs_in_error/",
      int(@jobs_list),
      ")\n";

# Termine le fils de scan des STDOUT et STDERR
close STDOUT;
close STDERR;

# Sort avec le nombre de process fils en erreur et avant parse la partie en erreur
if ($log and $mail_file) {
    my $mail_status = 'Success';
    if ($jobs_in_error) {
        $mail_status = "$jobs_in_error Error";
    }
    $ENV{LBD_MAIL_STATUS}   = $mail_status;
    my $job_file_name       = basename($file, ".txt");
    $ENV{LBD_JOB_FILENAME}  = $job_file_name;
    my $mail_file_name      = File::Spec->catfile(File::Spec->tmpdir(), $job_file_name . '_mail.html');
    $ENV{LBD_TMP_MAIL_FILE} = $mail_file_name;
    
    # Mode sympa, la génération de mail ne doit pas empêcher la sortie d'erreur.
    # Manip pour ne pas revoir la fonction format_log
    my $fh     = IO::File->new($mail_file_name, O_CREAT|O_EXCL|O_WRONLY);
    my $old_fh = select $fh;
    format_log($log, undef, $job_session, undef, undef, undef, 1);
    select $old_fh;
    close $fh;
    
    eval {
        lbd_sendmail({
            -file    => $mail_file,
        });
    };
    warn "$@\n" if $@;
    unlink $mail_file_name unless DEBUG;
}
exit $jobs_in_error;

format FMT_JOBS_HEADER =
   Started     Ended           Job         Status      State     Command
--------------------------------------------------------------------------------
.

format FMT_JOBS_LONG =
^|||||||||| ^|||||||||| ^||||||||||||||| @||||||||| @||||||||||| ^<<<<<<<<<<<<<<
@fmt_jobs
^|||||||||| ^|||||||||| ^|||||||||||||||                         ^<<<<<<<<<<<<<<
$fmt_jobs[0], $fmt_jobs[1], $fmt_jobs[2],                        $fmt_jobs[-1]
~~                                                               ^<<<<<<<<<<<<<<
                                                                 $fmt_jobs[-1]
.

format FMT_JOBS_SHORT =
^|||||||||| ^|||||||||| ^||||||||||||||| @||||||||| @||||||||||| ^<<<<<<<<<<<<<<
@fmt_jobs
.

format FMT_SESSION_HEADER =
Session                      State     Status
----------------------------------------------
.

format FMT_SESSION =
@<<<<<<<<<<<<<<<<<<<<<<<< @||||||||||| @<<<<<<<<<<<
@fmt_session
.

__END__

=pod

=for html <a name="top"><p><center>[<a href="index.html">Index</a>]</center></p><h1><center>tsmjobmonitor</center></h1>

=head1 NAME

tsmjobmonitor - Monitor le lancement de N process en parallèle

=head1 SYNOPSIS

Launch job (by file or/and by command line):

tsmjobmonitor {C<--job>=job}* C<--file>=job_list
C<--log>=logfilename
[C<--window>=start_window|C<--wait>=sleep_between_job]
[C<--maxprocess>=number|1000]

tsmjobmonitor C<--file>=job_list C<--redo>[=log_file] [C<--log>=logfilename] C<--session>=session_to_replay

tsmjobmonitor C<--session> C<--log>=logfilename

tsmjobmonitor C<--analyse> C<--log>=logfilename [C<--file>=job_list] [C<--Html>|C<--csv>|C<--Long>]

=head1 DESCRIPTION

tsmjobmonitor est utilisé pour lancer N jobs en parallèle. Une plage de lancement peut être précisée afin
de répartir le lancement dans le temps afin d'atténuer la charge du système d'exploitation dans
la création des threads/processus. Options: C<--window> ou C<--wait>.

Il est aussi possible de fixer le nombre maximum de processus à lancer en parallèle. Par défaut,
1000 processus en parallèle sont autorisés.

La sortie de la commande est générée à un format autodescriptif. C'est à dire que
le format du fichier permet les fonctions avancées du script: Reprise après erreur, compte-
rendu d'exécution.

La log est redirigée dans un fichier avec l'utilisation de l'option C<--log>. Il n'est pas exigé
de posséder un fichier de log par exécution, la log est écrite en mode C<append>. La génération
d'une log s'appuie sur un numéro de session d'exécution supposé unique.

Chaque lancement de la commande est appelée une session au format <date>:<process> afin d'obtenir un
id unique du point de vue du serveur de lancement (si le fichier de log est partagé NFS entre plusieurs
instances de tsmjobmonitor rien n'est garantie).

B<ATTENTION>: On suppose qu'un seul tsmjobmonitor fonctionne pour un fichier de log. Un verrou
est placé sur le fichier de log. Ce verrour est testé au début du script afin de ne pas
cumuler plusieurs exécution d'un même job. B<C'est le nom du fichier de log
qui identifie le job courant>.

Le numéro de session permet de retrouver une exécution dans le fichier de log. Cet id est utilisé
pour les compte-rendus et les reprises. La liste des sessions contenues dans un fichier de log est
affichée avec l'option C<--session>.

Il est à noter que lorsque que l'on utilise la notion de fichier de job, des fonctions étendues sont
possibles. Il est possible au sein
d'un job d'exécuter plusieurs commandes par étapes. Les branchements entre les étapes se font en
s'appuyant I<exclusivement> sur les codes retours des commandes. Les valeurs des codes retours peuvent
être paramétrées dans le fichier C<--file>.

B<ATTENTION>: Normalement, le lancement des jobs est aléatoire et ne respecte pas l'ordre du fichier
(du à l'implémentation
de la lecture du fichier de config). Cependant, si un job est prioritaire on peut lui appliquer l'option
priority avec une valeur numérique. Plus le nombre sera élevé plus le lancement sera prioritaire.

=head1 OPTIONS

=over

=item --job

Commande et ces arguments. Cette méthode est alternative à l'utilisation du fichier
de job. Dans ce cas, le nom des jobs est numérique dans l'odre de la ligne de
commande (à partir de 0).

=item --window

Durée en B<minute> de la plage de lancement pour l'ensemble des jobs. Cette valeur sera divisée
par le nombre de jobs pour connaître le temps d'attente nécessaire pour chaque job.

=item --wait

Pause à faire entre chaque lancement de jobs en B<seconde> (cette option ne fonctionne pas
lorsque que l'option C<--window> est utilisée).

=item --log

Nom du fichier de log

=item --file

Liste de job. Avec un job par ligne. Le format du fichier est exposé ci-dessous.
Aucune ligne n'est obligatoire

    # Modification du nombre de step max pour un job
    maxstep 4
    # Modification des codes retours testés pour enclencher
    # le step suivant
    success 0
    error   8
    warning 4
    fatal   12

    # Un job sous forme de commande unique. Le nom de job est positionné
    # automatiquement sous forme numérique. ici 0
    ls

    # Un job sous forme complète avec le nom "numero1"
    <job numero1>
    command ls /tmp # Dans ce cas le mot clé commande est obligatoire
    priority 1 # met une priorité + importante. + le nombre est élevé + la priorité est élevée.
    </job>

    # Un job "numéro2" possédant des steps. Le lien entre les steps est fait par les mots
    # clés success/warning/error/fatal
    <job numero2>
        # Step avec nom précisé
        <step step1>
            command ls /tmp
            # Mot clé permettant d'ignorer un step. Le step passe directement au step success
            ignore  yes
            success step2
            warning step3
        </step>
        <step step2>
            command ls /home
            # Pseudo step qui sort de la boucle.
            success exit
        </step>
        <step step3>
            command ls /usr
            error   step3
        </step>
    </job>

    # Génération de nom automatique pour le job et le step
    <job>
        # Par défaut, le step success s'oriente de manière séquentielle
        # Pour les autres step lorsqu'il n'y a rien d'indiqué on sort
        <step>
            command ls /var
        </step>
        <step>
            command ls /etc
        </step>
    </job>

    # Un job supplémentaire
    ls /var/tmp

=item --session

Numéro de session à reprendre. B<Cette option indique que l'on veut réaliser une reprise>. Ce numéro
est un id au format YYYY-MM-DD:HH:MM:SS:PID.

=item --redo

Fichier de log contenant les mots clés REDO et REDOSTEP de la session à reprendre. Si cette option
n'est pas indiquée, on tente de regarder dans le fichier indiqué par l'option C<--log> si on les retrouve.

=item --Html

Analyse la log et l'affiche au format Html

=item --csv

Analyse la log et l'affiche au format CSV

=item --Long

Affiche le format "standard" au format long (plusieurs lignes)

=item --verbose

Offre des options expliquant le fonctionnement de la commande notamment dans la lecture
du fichier de configuration.

=item --maxprocess

Définit le nombre maximum de process à exécuter en parallèle.

=back

=head1 EXAMPLES

    /tmp $ tsmjobmonitor --job='pwd' --job='echo $HOME'
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 438274)]  Starting session 05-04-07:10:41:52:438274.
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 458988)]  job(1): Launching 'echo $HOME'.
    [2005-04-07 10:41:52] [INFO]  [job(1)>echo (PID 458988>450800)] $HOME
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 450802)]  job(0): Launching 'pwd'.
    [2005-04-07 10:41:52] [INFO]  [job(0)>pwd (PID 450802>454894)] /tmp
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 438274)]  job(0): Ending 'pwd' (PID 450802). STATUS=0
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 438274)]  job(1): Ending 'echo $HOME' (PID 458988). STATUS=0
    [2005-04-07 10:41:52] [INFO]  [tsmjobmonitor (PID 438274)]  Ending session 05-04-07:10:41:52:438274. STATUS=0 (0/2)

    /tmp $ tsmjobmonitor --job='pwd' --job='echo $HOME' --job='uname' --wait=1
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 450814)]  Starting session 05-04-07:10:43:54:450814.
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 446704)]  job(2): Sleeping for '0's before launching 'uname'.
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 446704)]  job(2): Launching 'uname'.
    [2005-04-07 10:43:54] [INFO] [job(2)>uname (PID 446704>458996)] AIX
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 458998)]  job(1): Sleeping for '1's before launching 'echo $HOME'.
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 454900)]  job(0): Sleeping for '2's before launching 'pwd'.
    [2005-04-07 10:43:54] [INFO] [tsmjobmonitor (PID 450814)]  job(2): Ending 'uname' (PID 446704). STATUS=0
    [2005-04-07 10:43:55] [INFO] [tsmjobmonitor (PID 458998)]  job(1): Launching 'echo $HOME'.
    [2005-04-07 10:43:55] [INFO] [job(1)>echo (PID 458998>446706)] $HOME
    [2005-04-07 10:43:55] [INFO] [tsmjobmonitor (PID 450814)]  job(1): Ending 'echo $HOME' (PID 458998). STATUS=0
    [2005-04-07 10:43:56] [INFO] [tsmjobmonitor (PID 454900)]  job(0): Launching 'pwd'.
    [2005-04-07 10:43:56] [INFO] [job(0)>pwd (PID 454900>459000)] /tmp
    [2005-04-07 10:43:56] [INFO] [tsmjobmonitor (PID 450814)]  job(0): Ending 'pwd' (PID 454900). STATUS=0
    [2005-04-07 10:43:56] [INFO] [tsmjobmonitor (PID 450814)]  Ending session 05-04-07:10:43:54:450814. STATUS=0 (0/3)

    /tmp $ tsmjobmonitor --job='pwd' --job='echo $HOME' --job='uname' --window=1
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 458752)]  Starting session 05-04-07:10:46:26:458752.
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 446712)]  job(2): Sleeping for '0's before launching 'uname'.
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 446712)]  job(2): Launching 'uname'.
    [2005-04-07 10:46:26] [INFO]    [job(2)>uname (PID 446712>438312)] AIX
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 438314)]  job(1): Sleeping for '20's before launching 'echo $HOME'.
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 454660)]  job(0): Sleeping for '40's before launching 'pwd'.
    [2005-04-07 10:46:26] [INFO]    [tsmjobmonitor (PID 458752)]  job(2): Ending 'uname' (PID 446712). STATUS=0
    [2005-04-07 10:46:46] [INFO]    [tsmjobmonitor (PID 438314)]  job(1): Launching 'echo $HOME'.
    [2005-04-07 10:46:46] [INFO]    [job(1)>echo (PID 438314>446714)] $HOME
    [2005-04-07 10:46:46] [INFO]    [tsmjobmonitor (PID 458752)]  job(1): Ending 'echo $HOME' (PID 438314). STATUS=0
    [2005-04-07 10:47:06] [INFO]    [tsmjobmonitor (PID 454660)]  job(0): Launching 'pwd'.
    [2005-04-07 10:47:06] [INFO]    [job(0)>pwd (PID 454660>438320)] /tmp
    [2005-04-07 10:47:06] [INFO]    [tsmjobmonitor (PID 458752)]  job(0): Ending 'pwd' (PID 454660). STATUS=0
    [2005-04-07 10:47:06] [INFO]    [tsmjobmonitor (PID 458752)]  Ending session 05-04-07:10:46:26:458752. STATUS=0 (0/3)

    /tmp $ tsmjobmonitor --job='pwd' --job='echo $HOME' --job='uname' --log=/tmp/out
    /tmp $ tsmjobmonitor --analyse --log=/tmp/out
       Started     Ended           Job         Status      State     Command
    --------------------------------------------------------------------------------
    07/04 10:47 07/04 10:47        0          Success    Completed   pwd
    07/04 10:47 07/04 10:47        1          Success    Completed   echo $HOME
    07/04 10:47 07/04 10:47        2          Success    Completed   uname

    /tmp $ tsmjobmonitor --analyse --log=/tmp/out --csv
    Started;Ended;Job;Status;State;Command
    07/04 10:47;07/04 10:47;0;Success;Completed;pwd
    07/04 10:47;07/04 10:47;1;Success;Completed;echo $HOME
    07/04 10:47;07/04 10:47;2;Success;Completed;uname

    /tmp $ tsmjobmonitor --job='pwd' --job='ls /zorglub' --job='uname' --log=/tmp/out
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 450594)]  Starting session 05-04-07:10:51:28:450594.
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 454666)]  job(2): Launching 'uname'.
    [2005-04-07 10:51:28] [INFO]    [job(2)>uname (PID 454666>438330)] AIX
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 438332)]  job(1): Launching 'ls /zorglub'.
    [2005-04-07 10:51:28] [INFO]    [job(1)>ls (PID 438332>446468)] ls: 0653-341 The file /zorglub does not exist.
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 446470)]  job(0): Launching 'pwd'.
    [2005-04-07 10:51:28] [INFO]    [job(0)>pwd (PID 446470>463082)] /tmp
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 450594)]  job(0): Ending 'pwd' (PID 446470). STATUS=0
    [2005-04-07 10:51:28] [ERROR]   [tsmjobmonitor (PID 450594)]  job(1): Ending 'ls /zorglub' (PID 438332). STATUS=2
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 450594)]  job(2): Ending 'uname' (PID 454666). STATUS=0
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 450594)]  REDO=05-04-07:10:51:28:450594=1
    [2005-04-07 10:51:28] [INFO]    [tsmjobmonitor (PID 450594)]  Ending session 05-04-07:10:51:28:450594. STATUS=1 (1/3)

    /tmp $ tsmjobmonitor --job='pwd' --job='ls /zorglub' --job='uname' --redo=/tmp/out
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  Starting session 05-04-07:10:56:52:450632.
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  job(2): Launching 'Skipping job'.
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  job(2): Ending 'Skipping job' STATUS=0.
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 454670)]  job(1): Launching 'ls /zorglub'.
    [2005-04-07 10:56:52] [INFO]    [job(1)>ls (PID 454670>438338)] ls: 0653-341 The file /zorglub does not exist.
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  job(0): Launching 'Skipping job'.
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  job(0): Ending 'Skipping job' STATUS=0.
    [2005-04-07 10:56:52] [ERROR]   [tsmjobmonitor (PID 450632)]  job(1): Ending 'ls /zorglub' (PID 454670). STATUS=2
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  REDO=05-04-07:10:56:52:450632=1
    [2005-04-07 10:56:52] [INFO]    [tsmjobmonitor (PID 450632)]  Ending session 05-04-07:10:56:52:450632. STATUS=1 (1/3)

    /tmp $ tsmjobmonitor --session --log=/tmp/out
    Session                    State     Status
    --------------------------------------------
    05-04-07:10:47:54:45057  Completed   Success
    05-04-07:10:51:16:45059  Completed   Error=1
    05-04-07:10:52:38:45060  Completed   Error=1
    05-04-07:10:58:13:45063  Completed   Error=1

    /tmp $ tsmjobmonitor --session=05-04-07:10:47:54:45057 --log=/tmp/out
    tsmjobmonitor: [warning] No step to replay with log file '/tmp/out' for session '05-04-07:10:47:54:45057'.

=head1 BUGS

Gestion du fichier de log unique pour éviter les remplissages concurrents.

B<ATTENTION>: le script utilise la fonction flock qui ne fonctionne pas
pour un fichier NFS.

=head1 ENVIRONMENT

=head2 LBD_JOB_RC

Dans le cadre des steps, à la fin de l'exécution, le code retour du job
de step est renseigné dans cette variable d'environnement.

Ceci permet au job suivant de s'adapter à la situation.

Par principe lors d'enchainement de STEP, c'est le dernier code retour
qui donne le code retour du step complet.

=head1 SEE ALSO

fork(3), open3(3)

=head1 AUTHOR

Laurent Bendavid, <laurent.bendavid@dassault-aviation.com>

=head1 NOTES

=over

=item Version

2.5

=item History

Created 7/29/2003, Modified 1/24/08 23:40:50

=back

=for html <hr width="100%"><p><center>[<a href="#top">Top</a>]</center></p>

=cut

