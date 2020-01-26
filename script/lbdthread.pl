#!/usr/local/bin/perl

#Version Thread
use threads;
use threads::shared;
use Thread::Queue;
use File::Basename;
use strict;
use POSIX;

# DEBUG
#use Data::Dumper;
use constant DEBUG => $ENV{DEBUG};

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

# Variables d'environnement globales pour le fonctionnement du script
my %global=(
	success => 0,
	warning => 4,
	error   => 8,
	fatal   => 12,
	maxstep => 20, # Attention à ne pas mettre une valeur identique à une autre entrée (pour le défaut) !!! Bug assuré
);
my %to_global; # Pour accélerer la recherche inversée
while (my ($str, $value) = each %global) {
	$to_global{$value} = $str;
}
# Affichage format HTML

sub html_table_line_header {
	print '<TABLE WIDTH="80%" BORDER="1" CELLSPACING="0" CELLPADDING="3">',"\n",
		  '<TR BGCOLOR="darkblue">',"\n";
	foreach my $title (@_) {
		print "<TH><FONT COLOR=\"white\">$title</FONT></TH>";
	}
	print '</TR>',"\n";
}

sub html_table_line {
	my $color=shift;
	print "<TR ALIGN=\"center\" BGCOLOR=\"$color\">";
	foreach my $value (@_) {
		print "<TD>$value</TD>";
	}
	print "</TR>\n";
}

sub html_table_line_end {
	print '</TABLE>',"\n";
}

sub csv_line {
	print join(";",@_),"\n";
}

# Gestion des traces
sub log_msg {
	my ($level, $progname, $pid) = @_;
	
	$progname ||= basename($0) unless $progname;
	$pid      ||= $$;

	my $blank1 = 8 - length($level); # length("warning") = 8 le plus long

	return  strftime('[%Y-%m-%d %H:%M:%S] ',localtime(time))
		   . '[' . uc($level) . '] '
	   . ' ' x $blank1
	   . '[' . $progname . ' (PID ' . $pid .')] ';
}

# Execution du job avec ajout d'un en tête au ligne
sub exec_job {
	my ($job, $command, $step) = @_;
	
	#require IPC::Open3;
	#IPC::Open3->import();
	require Text::ParseWords;
	Text::ParseWords->import();
	
	my @cmd     = shellwords($command);
	my @logs;
	
	push @logs, &log_msg('info', "job($job)"), "job($job): Start $step exec '$command'.\n";
	my ($pid, $reader);
	#unless ($pid = open3(undef, $reader, undef, @cmd)) { # Open 3 pour rediriger STDERR dans STDOUT et ne pas le perdre
	#	push @logs, log_msg('error', "job($job)", $pid), "Cannot fork '$command': $!\n";
	#	return (8, \@logs);
	#}
	unless (open($reader, '-|', @cmd)) { # Open 3 pour rediriger STDERR dans STDOUT et ne pas le perdre
		push @logs, log_msg('error', "job($job)", $pid), "Cannot fork '$command': $!\n";
		return (8, \@logs);
	}
	DEBUG && warn "DEBUG:exec_job($job): pid=$pid cmd=$command\n";
	while (my $output = <$reader>) {
		push @logs, log_msg('info', "$job", "*"), $output;
	}
	close $reader; # Pouvoir traquer explicitement le RC
	DEBUG && warn "DEBUG:exec_job($job): waitpid $pid\n";
	#waitpid $pid, 0;
	my $rc = $? >> 8;
	DEBUG && warn "DEBUG:exec_job($job): end rc=$rc\n";
	
	my $level = (exists $to_global{$rc}) ? $to_global{$rc} : "error"; # Step suivant, fonction du  résultat de la commande
	push @logs, &log_msg($level, "job($job)"),"job($job): Ended $step '$command' STATUS=$rc\n";
	
	return ($rc, \@logs);
}

sub analyse_log {
	my ($file)=@_;

	my $array_session = [];
	my $hash_session  = {};

	my ($current_session);
	
	my $regexp_date = qr/\d\d\d\d[- ](\d\d)[- ](\d\d)[- :](\d\d):(\d\d).*/;
	
	open my $fh, '<', $file or die "lbdjob:analyse: [error] Cannot open file '$file': $!\n";
	while (<$fh>) {
		chomp;

		# Enregistrement de la session
		if (my ($start, $s) = (m/^\[([^\]]+)\].*Start session ([-:\d]+)/)) {
			$current_session=$s;
			push(@{$array_session},$current_session);
			$hash_session->{$current_session}->{STATE}  = 'Running';
			$hash_session->{$current_session}->{STATUS} = '-';
			$hash_session->{$current_session}->{START}  = $start;
			$hash_session->{$current_session}->{ENDED}  = '-';

			next;
		}

		# Enregistrement Job
		if (my ($begintime, $job, $command) = (m/^\[([^\]]+)\].*job\(([^\)]+)\): Start [^']*\'([^\']+)\'/)) {
			$hash_session->{$current_session}->{JOB}->{$job}->{STATE}   = 'Running';
			$hash_session->{$current_session}->{JOB}->{$job}->{COMMAND} = $command;
			$hash_session->{$current_session}->{JOB}->{$job}->{STATUS}  = '-';
			$hash_session->{$current_session}->{JOB}->{$job}->{BEGIN}   = $begintime;
			
			# Si compte-rendu de STEP
			if (my ($job_name, $step_name) = ($job =~ m{^(\w+)/(\w+)})) {
				$hash_session->{$current_session}->{JOB}->{$job_name}->{COMMAND} = "$step_name: $command";
			}
			
			DEBUG && warn "DEBUG: session=$current_session; job=$job; begintime=$begintime\n";
			my $res = $begintime =~ s/$regexp_date/$2\/$1 $3:$4/;
			
			DEBUG && warn "DEBUG: map_time '$begintime' catch '$res', 1=$1; 2=$2; 3=$3; 4=$4; !!$regexp_date!!\n";
			
			$hash_session->{$current_session}->{JOB}->{$job}->{STARTED} = $begintime;
			next;
		}

		# Fin job
		if (my ($endtime, $job, $status) = (m/^\[([^\]]+)\].*job\(([^\)]+)\): Ended .*STATUS=(\d+)/)) {
			$status=($status)?("Error=$status"):("Success");
			$hash_session->{$current_session}->{JOB}->{$job}->{STATE}   = 'Completed';
			$hash_session->{$current_session}->{JOB}->{$job}->{STATUS}  = $status;
			$hash_session->{$current_session}->{JOB}->{$job}->{END}     = $endtime;
			$endtime =~ s/$regexp_date/$2\/$1 $3:$4/;
			$hash_session->{$current_session}->{JOB}->{$job}->{ENDED}   = $endtime;
			next;
		}

		# Fin session
		if (my ($end, $s, $status) = (m/^\[([^\]]+)\].*Ended session ([-:\d]+).*STATUS=(\d+)/)) {
			$hash_session->{$s}->{STATE}    = 'Completed';
			$status=($status)?("Error=$status"):("Success");
			$hash_session->{$s}->{STATUS}   = $status;
			$hash_session->{$s}->{ENDED}    = $end;
			next;
		}
	}
	close $fh;

	DEBUG && warn "DEBUG:analyse_log: ", Dumper($hash_session);
	return ($array_session, $hash_session);
}

sub format_log {
	my ($log, $job_list_ref, $opt_session, $long, $jobs_list_ref, $csv, $Html) = @_;

	require Term::ANSIColor;
	Term::ANSIColor->import();
	
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
	
	my ($array_session, $hash_session) = analyse_log($log);

	$opt_session = ($opt_session) ? ($opt_session) : ($array_session->[-1]);

	DEBUG && warn "DEBUG: get session '$opt_session'.\n";

	die "lbdjob: [error] Session number '$opt_session' does not exist in file '$log'.\n" unless exists $hash_session->{$opt_session};

	SWITCH: {
		$csv && do {
			csv_line(@fmt_jobs_header);
			last SWITCH;
		};
		$Html && do {
			html_table_line_header(@fmt_jobs_header);
			last SWITCH;
		};

		$~='FMT_JOBS_HEADER';
		write;
		$~ = ($long) ? ('FMT_JOBS_LONG') : ('FMT_JOBS_SHORT');
	}

	# Liste de recherche des jobs
	my @job_list = @{$jobs_list_ref};
	unless (@job_list) {
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

	DEBUG && warn "DEBUG: job list", Dumper(\@job_list, $job_list_ref);

	foreach my $job (@job_list) {
		if (exists $hash_session->{$opt_session}->{JOB}->{$job}) {
		@fmt_jobs = ($hash_session->{$opt_session}->{JOB}->{$job}->{STARTED},
						 $hash_session->{$opt_session}->{JOB}->{$job}->{ENDED},
						 $job,
						 $hash_session->{$opt_session}->{JOB}->{$job}->{STATUS},
						 $hash_session->{$opt_session}->{JOB}->{$job}->{STATE},
						 $hash_session->{$opt_session}->{JOB}->{$job}->{'COMMAND'},
		);
		} elsif ($job_list_ref) {
		@fmt_jobs = ('-', '-', $job, 'Waiting', $job_list_ref->{$job}->{'COMMAND'});
		}

		if ($csv) {
			csv_line(@fmt_jobs);
			next;
		}

		my $status = 'Running';
		   $status = 'Success' if ($fmt_jobs[3] =~ m/Success/);
		if (my ($rc) = ($fmt_jobs[3] =~ m/Error=(\d+)/)) {
		$status  = ucfirst($to_global{$rc});
		}

		if ($Html) {
			html_table_line($colors_html{$status}, @fmt_jobs);
		next;
		} 
	print color($colors_text{$status}) if (-t STDOUT);
	write;
	print color('RESET') if (-t STDOUT);
	}

	html_table_line_end() if $Html;
}
#----------
# Main
#----------

# Variables a recopier dans chaque thread
my (@jobs_queue, $job_list_ref, $redo_job, $max_workers);
my $fh = \*STDOUT;

# Traitement pré-threading pour limiter l'espace mémoire
my ($log, $mail_file, $file);
PREPARE_THREADING_OR_NOT_IN_THREAD: {
	# Traitement des options
	require Getopt::Long;
	Getopt::Long->import();
	require Pod::Usage;
	Pod::USage->import();
	
	my (
		$analyse, $redo, $opt_session, $long,
		$file, @job,
		$help, $verbose,
		$Html, $csv,
		$log, $mail_file,
		$max_process,
	);

	# Initialisation de valeur
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
			'mailfile'     => \$mail_file,
	) or pod2usage(-message => 'Bad options.');

	pod2usage(
		-verbose => 1,
		-exitval => 4,
	) if ($help);

	# Lit un fichier compliqué format Apache pour le futur, pour le moment prend
	# une liste de job
	my $parse_job_list = sub {
		require Text::Abbrev;
		Text::Abbrev->import();
		# Structure:
		#-----------
		#
		# struct JOB {
		#        nom      => Généré automatiquement si absent
#        COMMAND  => commande ou _JOB_STEPS_
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
	my ($job, $job_list_ref, $step_id_nb,$step, $step_before);
	my $job_id_nb = 1;

	open my $fh, "<$file" or die "lbdjob: Error - Cannot open file '$file': $!\n";
	LINE: while (<$fh>) {
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
					$job = $job_id_nb;
					$job_id_nb++;
				} else {
					$job = $job_id;
				}

				# Remise à zéro des steps pour un process
				$step       = undef;
				$step_id_nb = 1;

				next LINE;
			}

			# Enregistrement de STEP
			if (m/<(?i)step(?-i)\s*(\S*)>/ ... m/<\/(?i)step(?-i)[^>]*>/) {
				my $step_id = $1;

				if (m/<(?i)step(?-i)/) {
					# Sauvegarde du step précédent
					$step_before=$step;

					# Calcul du step nouveau
					unless ($step_id) {
						$step = $step_id_nb;
						$step_id_nb++;
					} else {
						$step = $step_id;
					}

					# Mise en place séquentiel simple s'il le faut
					if ($step_before && ! exists $job_list_ref->{$job}->{STEP}->{$step_before}->{command}) {
						warn  "lbdjob: [warning] Invalid step job($job/$step_before). Discarding...\n";
						$job_list_ref->{$job}->{STEP_INI} = $step if ($job_list_ref->{$job}->{STEP_INI} eq "$step_before");
						delete $job_list_ref->{$job}->{STEP}->{$step_before};
					} elsif($step_before) {
						$job_list_ref->{$job}->{STEP}->{$step_before}->{success} = $step unless (exists $job_list_ref->{$job}->{STEP}->{$step_before}->{success});
					}

					# Enregistrement du step de départ
					$job_list_ref->{$job}->{STEP_INI} = $step unless (exists $job_list_ref->{$job}->{STEP_INI});

					# Lanceur de step
					$job_list_ref->{$job}->{COMMAND}='_JOB_STEPS_';
					next LINE;
				}

				if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/) {
					my ($field, $value) = (lc($1), $2);

					if (exists $fields{$field}) {
						print "lbdjob: [info]  Registering job($job/$step) step option ",$fields{$field}," = '$value'.\n" if $verbose;
						$job_list_ref->{$job}->{STEP}->{$step}->{$fields{$field}} = $value;
					} else {
					   warn "lbdjob: [warning] Invalid field '$field'. Ignoring...\n";
					}
				}

				next LINE;
			}

			# Enregistrement de paramètre job
			if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/) {
				my ($field,$value)=(lc($1), $2);

				if (exists $fields{$field}) {
					if ($fields{$field} eq 'command') {
						$job_list_ref->{$job}->{COMMAND} = $value;
						print "lbdjob: [info]  Registering job($job) job command '$value'.\n" if $verbose;
					} else {
						print "lbdjob: [info]  Registering job($job) job option ",$fields{lc($field)}," = '$value'.\n" if $verbose;
						$job_list_ref->{$job}->{OPTION}->{$fields{$field}}=$value;
					}
				} else {
					warn "lbdjob: [warning] Invalid field '$field'. Ignoring...\n";
				}
			}

			next LINE;
		}

		DEBUG && warn "DEBUG:config_line: no apache job: $_\n";

		if (m/^\s*(\w+)\s+["'](.+)["']/ or m/^\s*(\w+)\s+(.+)/ or m/^\s*(\w+)/) {
			my ($field, $value) = (lc($1), $2);

			if (exists $fields{$field}) {
				print "lbdjob: [info]  Registering global option ",$fields{$field}," = '$value'.\n" if $verbose;
				$global{$fields{$field}}=$value;
				next LINE;
			}
		}
		# Job tout simple, pas à réfléchir
		s/^\s*//;
		print "lbdjob: [info]  Registering job($job_id_nb) = '$_'.\n" if $verbose;
		$job_list_ref->{$job_id_nb++}->{COMMAND} = $_;
	}
	close $fh;
	
	foreach my $global (keys %global) {
		$global{$global{$global}} = $global;
	}

	DEBUG && warn "DEBUG: ", Dumper($job_list_ref), "\n";
	return $job_list_ref;
	};
	$job_list_ref = $parse_job_list->($file, $verbose) if ($file);
	# Lecture à partir de la ligne de commande
	my $job_id_nb = 0;
	$job_list_ref->{"JOB".$job_id_nb++}->{COMMAND}=$_ foreach (@job);

	my @jobs_list = keys(%{$job_list_ref});

	DEBUG && warn "DEBUG:jobs_list=", Dumper(\@jobs_list), ", job_list_ref=", Dumper($job_list_ref), "\n";

	# Options non threadé
	# Analyse de la log
	if (defined $analyse) {
		DEBUG && warn "DEBUG: analyse\n";

		pod2usage(-message => 'Need log file') unless $log;
		format_log($log, $job_list_ref, $opt_session, $long, \@jobs_list, $csv, $Html);

		exit(0);
	}

	if (defined $opt_session and not defined $redo) {
		pod2usage(-message => 'Need log file') unless $log;
		my ($array_session, $hash_session) = analyse_log($log);

		SWITCH: {
			$Html && do {
				html_table_line_header(@fmt_session_header, "Start Time", "End Time");
				last SWITCH;
			};
			$csv && do {
				csv_line(@fmt_session_header, "Start Time", "End Time");
				last SWITCH;
			};
			$~ = 'FMT_SESSION_HEADER';
			write;
			$~ = 'FMT_SESSION';
		}

		foreach my $s (@{$array_session}) {
			@fmt_session = ($s, $hash_session->{$s}->{STATE}, $hash_session->{$s}->{STATUS});
			SWITCH: {
				if ($Html) {
					my $color='lightyellow';
					$color = 'lightgreen'  if ($fmt_session[2] =~ m/Success/);
					$color = 'lightsalmon' if ($fmt_session[2] =~ m/Error/);
					html_table_line($color,@fmt_session, $hash_session->{$s}->{START}, $hash_session->{$s}->{ENDED});
					last SWITCH;
				}
				if ($csv) {
					csv_line(@fmt_session, $hash_session->{$s}->{START}, $hash_session->{$s}->{ENDED});
					last SWITCH;
				}
				write;
			}
		}

		html_table_line_end() if $Html;

		exit(0);
	}

	if (defined $redo) {
		# Mode redo
		my $redo_file = ($redo) ? ($redo) : ($log);

		pod2usage(-message => 'Need redo file.') unless -f $redo_file;
		print "Use redo log: $redo_file\n";
		my ($array_session, $hash_session) = analyse_log($redo_file);
	
		$opt_session = ($opt_session)?($opt_session):($array_session->[-1]);
		print "Use session: $opt_session\n";
	
		pod2usage(-message => 'Need valid session number') unless exists $hash_session->{$opt_session};

		my $parse_redo_log = sub {
			my ($file, $session)=@_;
			$session = quotemeta($session);
			local $_;
			my %redo;

			open my $fh, "<$file" or die "lbdjob: Error - Cannot open file '$file': $!\n";
			while (<$fh>) {
				chomp;

				my ($job, $step);

				if (($job) = (m/REDO=$session=(\S+)/) ) {
					$redo{$job}->{STATUS}++;
					next;
				}

				if (($job,$step) = (m/REDOSTEP=$session=([^=]+)=(\S+)/) ) {
					$redo{$job}->{STEP}->{$step}++;
					next;
				}
			}
			close $fh;

			# Ménage pour les jobs steps qui se rétablissent tout seul
			while (my ($key, $value) = each(%redo)) {
				delete $redo{$key} unless (exists $redo{$key}->{STATUS});
			}

			return unless (%redo);
			DEBUG && warn "DEBUG:parse_redo:", Dumper(\%redo);
			return \%redo;
		};

		$redo_job = $parse_redo_log->($redo_file, $opt_session);
		die "No step to replay with log file '$redo_file' for session '$opt_session'.\n" unless $redo_job;
	}

	# Vérification et initialisation
	pod2usage({
		-message => 'No sufficient argument.',
		-exitval => 2,
	}) unless ($job_list_ref);

	# Test du lock pour ne pas être bloquant (mode abandon)
	if ($log) {
		open my $fh_log, '>>', $log or die "lbdjob: Error - Cannot test lock: $!\n";
		my $lock   = flock($fh_log, 2 | 4);
		flock($fh_log, 8) if $lock;
		$fh_log->close();
		die "Error - An other process use your file log '$log'\n" unless ($lock);
		open $fh, '>>', $log or die "lbdjob: Error - Cannot open file '$log': $!\n";
		$fh->autoflush(1);
		# Assure qu'un seul process utilise le fichier
		flock($fh, 2);
	}
	
	# Préparation de la mécanique multiprocess
	@jobs_queue = sort {
		$job_list_ref->{$b}->{OPTION}->{priority} <=> $job_list_ref->{$a}->{OPTION}->{priority};
	} @jobs_list;
	$max_workers = (scalar(@jobs_queue) < $max_process) ? scalar(@jobs_queue) : $max_process;
	DEBUG && warn "DEBUG:max_workers=$max_workers|$max_process\n";
}

# On flush les entrées / sorties pour tout le programme
select STDERR ; $|=1;
select STDOUT ; $|=1;

#-------------
# Démarrage du père qui travaille!!
#-------------

# Creation de la session
my $job_session = strftime("%y-%m-%d:%H:%M:%S:$$",localtime(time()));
print $fh &log_msg('info'), "Start session $job_session.\n";

DEBUG && warn "DEBUG:jobs_runqueue=", Dumper(\@jobs_queue);

# Démarrage en mode Threading
my $jobs_queue = Thread::Queue->new();

# Création des Threads
my $lock_thread : shared = "print";

my $thread_exec = sub {
	my $tid           = threads->self->tid();
	my $jobs_in_error = 0;
	
	JOB_QUEUE: while (my $current_job = $jobs_queue->dequeue()) {
		my $job_run_ref = $job_list_ref->{$current_job};
		
		DEBUG && warn "DEBUG:Thread($tid):exec($current_job): $redo_job\n";
		# Ne reprend que les jobs marqués, cas REDO
		if ($redo_job and ! exists $redo_job->{$current_job}->{STATUS}) {
			THREAD_LOCK: {
				lock $lock_thread;
				print $fh log_msg('info', "job($current_job)", $tid), "job($current_job): Start 'Skip job'.\n",
						  log_msg('info', "job($current_job)", $tid), "job($current_job): Ended 'Skip job'. STATUS=0.\n";
			}
			next JOB_QUEUE;
		}

		DEBUG && warn "DEBUG:Thread($tid):exec($current_job)\n";
		# Lancement du job
		my $command = $job_run_ref->{COMMAND};
		THREAD_LOCK: {
			lock $lock_thread;
			print $fh log_msg('info', "job($current_job)", $tid), "job($current_job): Start '$command'\n";
		}
		my ($job_rc, @logs);
		
		if (exists $job_run_ref->{STEP_INI}) {			
			my $maxstep      = $global{maxstep};
			my $step         = $job_run_ref->{STEP_INI};
			my $counter      = 0;
			my $rc           = 0;
			my $last_level   = 'info';

			STEP: while ($step) {
				last STEP if ($step eq "exit");
				
				THREAD_LOCK: {
					lock $lock_thread;
					print $fh log_msg('info', "job($current_job/$step)", $tid), "job($current_job/$step): Start '$step'\n";
				}

				unless (exists $job_run_ref->{STEP}->{$step}) {
					push @logs, log_msg('error', "job($current_job/$step)", $tid), "job($current_job/$step): Ended step '$step' STATUS=12. Step does not exist\n";
					$rc = 8;
					last STEP;
				}
				$counter++;

				my $cmd = $job_run_ref->{STEP}->{$step}->{command};
				if ($counter > $maxstep) {
					push @logs, log_msg('error', "job($current_job/$step)", $tid), "job($current_job/$step): Ended step '$cmd' STATUS=12. Maxstep exceeded '$maxstep'\n";
					$rc = 8;
					last STEP;
				}

				my @logs_step;
				# Gestion de la reprise dans 1 step
				if ($redo_job and exists $redo_job->{$current_job}) {
					if (exists $redo_job->{$current_job}->{STEP}->{$step}) {
						# On reprends le cours normal des steps à partir de maintenant
						delete $redo_job->{$current_job};
					} else {
						# On ignore le step, on passera au suivant
						$job_run_ref->{STEP}->{$step}->{ignore}++;
					}
				}

				if ($job_run_ref->{STEP}->{$step}->{ignore}) {
					$rc = 0;
					push @logs_step, log_msg('info', "job($current_job/$step)", $tid),"job($current_job/$step): Skip step '$cmd'.\n";
				} else {
					my $logs_ref;
					($rc, $logs_ref) = exec_job("$current_job/$step", $cmd, 'step');
					push @logs_step, @{$logs_ref};
				}
		
				$ENV{LBD_JOB_RC}       = $rc; # Pour usage dans les autres scripts
				$ENV{LBD_JOB_PREVIOUS} = $cmd;
	
				DEBUG && warn "DEBUG:Step: step=$current_job/$step, rc=$rc\n";
	
				# Cas d'erreur, $rc != 0, tag de reprise
				push @logs_step, &log_msg('info', "job($current_job/$step)", $tid),"REDOSTEP=$job_session=$current_job=$step\n" if ($rc);

				my $level = (exists $to_global{$rc}) ? $to_global{$rc} : "error"; # Step suivant, fonction du  résultat de la commande
				THREAD_LOCK: {
					lock $lock_thread;
					print $fh @logs_step;
				}

				$last_level = $level;
	
				$step = $job_run_ref->{STEP}->{$step}->{$level}; # Next step
			}
			push @logs, log_msg($last_level, "job($current_job)", $tid), "job($current_job): Ended 'JOB STEPS' STATUS=$rc\n";

			$job_rc = $rc;
		} else {
			my $logs_ref;
			($job_rc, $logs_ref) = exec_job($current_job, $command);
			push @logs, @{$logs_ref};
		}
		
		DEBUG && warn "DEBUG:Thread[$tid] lock for print ", scalar(localtime);
		THREAD_LOCK: { # Pour écrire sereinement 
			lock $lock_thread;
			if ($job_rc) {
				# Increment le compteur de nombre de job en erreur
				$jobs_in_error++;
				# On le stack dans les piles des jobs pour un redo
				print $fh log_msg('info', $current_job, $tid), "REDO=$job_session=$current_job\n";
			}
			print $fh @logs;
			# Libère le lock en sortant du bloc
		}
		DEBUG && warn "DEBUG:Thread[$tid] unlock for print", , scalar(localtime);
	}
	$jobs_queue->enqueue(undef); # Pour débloquer les autres Threads
	
	return $jobs_in_error;	
};

# Préparation des workers
warn "Start build workers...\n";
my %threads;
foreach my $worker (1 .. $max_workers) {
	my $thread = threads->new($thread_exec);
	my $tid    = $thread->tid();
	DEBUG && warn "DEBUG:Thread($tid): Create\n";
	$threads{$thread}++;
}
warn "All workers ready...\n";

# Worker créé, on peut lancer les travaux!
warn "Queuing work!\n";
$jobs_queue->enqueue(@jobs_queue);
# Undef débloque la file : cela veut dire que c'est terminé.
$jobs_queue->enqueue(undef);
warn "Queue full, start waiting\n";
# C'est parti, plus qu'à attendre la fin des threads

DEBUG && warn "DEBUG: waiting...\n";
my $jobs_in_error = 0;

while (threads->list(threads::all)) {
	foreach my $thread (threads->list(threads::joinable)) {
		my $tid = $thread->tid();
		my $rc = $thread->join();
		DEBUG && warn "DEBUG:Thread($tid): End $rc\n";
		$jobs_in_error += $rc;
	}
}

# Fin de session
print $fh &log_msg('info'), "Ended session $job_session. STATUS=$jobs_in_error\n";

# Sort avec le nombre de process fils en erreur et avant parse la partie en erreur
if ($log and $mail_file) {
	my $mail_status = 'Success';
	if ($jobs_in_error) {
		$mail_status = "$jobs_in_error Error";
	}
	
	require File::Spec;
	File::Spec->import();
	require DA::Lbd::Mail;
	DA::Lbd::Mail->import();
	
	$ENV{LBD_MAIL_STATUS}   = $mail_status;
	my $job_file_name       = basename($file, ".txt");
	$ENV{LBD_JOB_FILENAME}  = $job_file_name;
	my $mail_file_name      = File::Spec->catfile(File::Spec->tmpdir(), $job_file_name . '_mail.html');
	$ENV{LBD_TMP_MAIL_FILE} = $mail_file_name;
	
	# Mode sympa, la génération de mail ne doit pas empêcher la sortie d'erreur.
	# Manip pour ne pas revoir la fonction format_log
	open my $fh, '>', $mail_file_name or die "Cannot open mail file '$mail_file_name': $!\n";
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

=for html <a name="top"><p><center>[<a href="index.html">Index</a>]</center></p><h1><center>lbdjob</center></h1>

=head1 NAME

lbdjob - Monitor le lancement de N process en parallèle

=head1 SYNOPSIS

Launch job (by file or/and by command line):

lbdjob {C<--job>=job}* C<--file>=job_list
C<--log>=logfilename
[C<--window>=start_window|C<--wait>=sleep_between_job]
[C<--maxprocess>=number|1000]

lbdjob C<--file>=job_list C<--redo>[=log_file] [C<--log>=logfilename] C<--session>=session_to_replay

lbdjob C<--session> C<--log>=logfilename

lbdjob C<--analyse> C<--log>=logfilename [C<--file>=job_list] [C<--Html>|C<--csv>|C<--Long>]

=head1 DESCRIPTION

lbdjob est utilisé pour lancer N jobs en parallèle. Une plage de lancement peut être précisée afin
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
instances de lbdjob rien n'est garantie).

B<ATTENTION>: On suppose qu'un seul lbdjob fonctionne pour un fichier de log. Un verrou
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

	/tmp $ lbdjob --job='pwd' --job='echo $HOME'
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 438274)]  Start session 05-04-07:10:41:52:438274.
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 458988)]  job(1): Start 'echo $HOME'.
	[2005-04-07 10:41:52] [INFO]  [job(1)>echo (PID 458988>450800)] $HOME
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 450802)]  job(0): Start 'pwd'.
	[2005-04-07 10:41:52] [INFO]  [job(0)>pwd (PID 450802>454894)] /tmp
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 438274)]  job(0): Ended 'pwd' (PID 450802). STATUS=0
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 438274)]  job(1): Ended 'echo $HOME' (PID 458988). STATUS=0
	[2005-04-07 10:41:52] [INFO]  [lbdjob (PID 438274)]  Ended session 05-04-07:10:41:52:438274. STATUS=0 (0/2)

	/tmp $ lbdjob --job='pwd' --job='echo $HOME' --job='uname' --wait=1
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 450814)]  Start session 05-04-07:10:43:54:450814.
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 446704)]  job(2): Sleeping for '0's before Start 'uname'.
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 446704)]  job(2): Start 'uname'.
	[2005-04-07 10:43:54] [INFO] [job(2)>uname (PID 446704>458996)] AIX
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 458998)]  job(1): Sleeping for '1's before Start 'echo $HOME'.
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 454900)]  job(0): Sleeping for '2's before Start 'pwd'.
	[2005-04-07 10:43:54] [INFO] [lbdjob (PID 450814)]  job(2): Ended 'uname' (PID 446704). STATUS=0
	[2005-04-07 10:43:55] [INFO] [lbdjob (PID 458998)]  job(1): Start 'echo $HOME'.
	[2005-04-07 10:43:55] [INFO] [job(1)>echo (PID 458998>446706)] $HOME
	[2005-04-07 10:43:55] [INFO] [lbdjob (PID 450814)]  job(1): Ended 'echo $HOME' (PID 458998). STATUS=0
	[2005-04-07 10:43:56] [INFO] [lbdjob (PID 454900)]  job(0): Start 'pwd'.
	[2005-04-07 10:43:56] [INFO] [job(0)>pwd (PID 454900>459000)] /tmp
	[2005-04-07 10:43:56] [INFO] [lbdjob (PID 450814)]  job(0): Ended 'pwd' (PID 454900). STATUS=0
	[2005-04-07 10:43:56] [INFO] [lbdjob (PID 450814)]  Ended session 05-04-07:10:43:54:450814. STATUS=0 (0/3)

	/tmp $ lbdjob --job='pwd' --job='echo $HOME' --job='uname' --window=1
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 458752)]  Start session 05-04-07:10:46:26:458752.
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 446712)]  job(2): Sleeping for '0's before Start 'uname'.
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 446712)]  job(2): Start 'uname'.
	[2005-04-07 10:46:26] [INFO]    [job(2)>uname (PID 446712>438312)] AIX
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 438314)]  job(1): Sleeping for '20's before Start 'echo $HOME'.
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 454660)]  job(0): Sleeping for '40's before Start 'pwd'.
	[2005-04-07 10:46:26] [INFO]    [lbdjob (PID 458752)]  job(2): Ended 'uname' (PID 446712). STATUS=0
	[2005-04-07 10:46:46] [INFO]    [lbdjob (PID 438314)]  job(1): Start 'echo $HOME'.
	[2005-04-07 10:46:46] [INFO]    [job(1)>echo (PID 438314>446714)] $HOME
	[2005-04-07 10:46:46] [INFO]    [lbdjob (PID 458752)]  job(1): Ended 'echo $HOME' (PID 438314). STATUS=0
	[2005-04-07 10:47:06] [INFO]    [lbdjob (PID 454660)]  job(0): Start 'pwd'.
	[2005-04-07 10:47:06] [INFO]    [job(0)>pwd (PID 454660>438320)] /tmp
	[2005-04-07 10:47:06] [INFO]    [lbdjob (PID 458752)]  job(0): Ended 'pwd' (PID 454660). STATUS=0
	[2005-04-07 10:47:06] [INFO]    [lbdjob (PID 458752)]  Ended session 05-04-07:10:46:26:458752. STATUS=0 (0/3)

	/tmp $ lbdjob --job='pwd' --job='echo $HOME' --job='uname' --log=/tmp/out
	/tmp $ lbdjob --analyse --log=/tmp/out
	   Started     Ended           Job         Status      State     Command
	--------------------------------------------------------------------------------
	07/04 10:47 07/04 10:47        0          Success    Completed   pwd
	07/04 10:47 07/04 10:47        1          Success    Completed   echo $HOME
	07/04 10:47 07/04 10:47        2          Success    Completed   uname

	/tmp $ lbdjob --analyse --log=/tmp/out --csv
	Started;Ended;Job;Status;State;Command
	07/04 10:47;07/04 10:47;0;Success;Completed;pwd
	07/04 10:47;07/04 10:47;1;Success;Completed;echo $HOME
	07/04 10:47;07/04 10:47;2;Success;Completed;uname

	/tmp $ lbdjob --job='pwd' --job='ls /zorglub' --job='uname' --log=/tmp/out
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 450594)]  Start session 05-04-07:10:51:28:450594.
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 454666)]  job(2): Start 'uname'.
	[2005-04-07 10:51:28] [INFO]    [job(2)>uname (PID 454666>438330)] AIX
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 438332)]  job(1): Start 'ls /zorglub'.
	[2005-04-07 10:51:28] [INFO]    [job(1)>ls (PID 438332>446468)] ls: 0653-341 The file /zorglub does not exist.
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 446470)]  job(0): Start 'pwd'.
	[2005-04-07 10:51:28] [INFO]    [job(0)>pwd (PID 446470>463082)] /tmp
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 450594)]  job(0): Ended 'pwd' (PID 446470). STATUS=0
	[2005-04-07 10:51:28] [ERROR]   [lbdjob (PID 450594)]  job(1): Ended 'ls /zorglub' (PID 438332). STATUS=2
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 450594)]  job(2): Ended 'uname' (PID 454666). STATUS=0
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 450594)]  REDO=05-04-07:10:51:28:450594=1
	[2005-04-07 10:51:28] [INFO]    [lbdjob (PID 450594)]  Ended session 05-04-07:10:51:28:450594. STATUS=1 (1/3)

	/tmp $ lbdjob --job='pwd' --job='ls /zorglub' --job='uname' --redo=/tmp/out
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  Start session 05-04-07:10:56:52:450632.
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  job(2): Start 'Skip job'.
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  job(2): Ended 'Skip job' STATUS=0.
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 454670)]  job(1): Start 'ls /zorglub'.
	[2005-04-07 10:56:52] [INFO]    [job(1)>ls (PID 454670>438338)] ls: 0653-341 The file /zorglub does not exist.
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  job(0): Start 'Skip job'.
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  job(0): Ended 'Skip job' STATUS=0.
	[2005-04-07 10:56:52] [ERROR]   [lbdjob (PID 450632)]  job(1): Ended 'ls /zorglub' (PID 454670). STATUS=2
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  REDO=05-04-07:10:56:52:450632=1
	[2005-04-07 10:56:52] [INFO]    [lbdjob (PID 450632)]  Ended session 05-04-07:10:56:52:450632. STATUS=1 (1/3)

	/tmp $ lbdjob --session --log=/tmp/out
	Session                    State     Status
	--------------------------------------------
	05-04-07:10:47:54:45057  Completed   Success
	05-04-07:10:51:16:45059  Completed   Error=1
	05-04-07:10:52:38:45060  Completed   Error=1
	05-04-07:10:58:13:45063  Completed   Error=1

	/tmp $ lbdjob --session=05-04-07:10:47:54:45057 --log=/tmp/out
	lbdjob: [warning] No step to replay with log file '/tmp/out' for session '05-04-07:10:47:54:45057'.

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

