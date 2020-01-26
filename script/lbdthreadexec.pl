#!/usr/local/bin/perl

#Version Thread
use threads;
use threads::shared;
use Thread::Queue;
use Text::ParseWords;
use IPC::Cmd qw(run);
use strict;
use CGI::Carp;
use IO::Select;

# DEBUG
#use Data::Dumper;
use constant DEBUG => $ENV{DEBUG};

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

my $Thread_Lock : shared = 0;

# Gestion des traces
sub log_msg {
	my ($level, $progname, $pid) = @_;
		
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	
	return sprintf('[%d-%02d-%02d %02d:%02d:%02d] %-10s [%s (PID %d)] ',
					$year+1900, $mon+1, $mday, $hour, $min, $sec,
					'['.uc($level).'] ',
					$progname,
					$pid || $$,
					);
}

# Execution du job avec ajout d'un en tête au ligne
sub exec_job {
	my ($job, $cmd) = @_;

	my @cmd = shellwords($cmd);
	my $step = ($job =~ m{/}) ? 'step' : '';
	
	my @buffer;
	push @buffer, log_msg('info', "job($job)"), "job($job): Start $step exec '$cmd'.\n";
	my ($cmd_h, $child_pid);
	
	my $tid = threads->tid();
	warn "DEBUG[$tid] todo=@cmd.\n";
	THREAD_LOCK: {
		warn "DEBUG[$tid]:try_lock-fork=$Thread_Lock\n";
		lock $Thread_Lock;
		$Thread_Lock = "Locked by $tid: @cmd";
		$child_pid = open $cmd_h, '-|';
		if (not defined $child_pid) {
			die "$tid: Cannot create child: $!\n";
		}
	}
	warn "DEBUG[$tid]:unlock-fork=$Thread_Lock\n";
	
	if ($child_pid == 0) {
		# Dans le fils
		# On duplique STDERR
		warn "DEBUG[$tid]:Child: 2>&1 & bye: @cmd\n";
		open(STDERR, '>&STDOUT') or die "Cannot 2>&1: $!\n";
		exec(@cmd);
	}
	warn "DEBUG[$tid]:Parent: read\n";
	#open my $cmd_h, '-|', @cmd or die "Cannot fork '$cmd': $!\n";
	
	my $s = IO::Select->new();
	$s->add($cmd_h);
	READ: while (1) {
		warn "DEBUG[$tid]:Parent: can read test: @cmd\n";
		THREAD_LOCK: {
			lock $Thread_Lock;
			$Thread_Lock = "Lock read $tid: @cmd";
			warn "DEBUG[$tid]:Parent: lock for read: @cmd\n";
			last THREAD_LOCK unless ($s->can_read(2));
			
			warn "DEBUG[$tid]:Parent: test eof?\n";
			last READ if (eof($cmd_h));
			
			warn "DEBUG[$tid]:Parent: read now\n";
			my $buffer = <$cmd_h>;
			push @buffer, log_msg('info', "job($job)"), $buffer;
			
			warn "DEBUG[$tid]:Parent: unlock for read: @cmd\n";
			next READ;
		}
		warn "DEBUG[$tid]:Parent: unlock not ready: @cmd\n";
		threads->yield();
		sleep 1;
		
	}
	
	waitpid $child_pid, 0;
	my $rc    = $? >> 8;
	close $cmd_h;
	
	warn "DEBUG[$tid]:Parent:exit: $?, $rc, $!\n";
	my $level = ($rc) ? 'error' : 'success';

			
	push @buffer, log_msg($level, "job($job)"), "job($job): Ended $step exec '$cmd': $!\n";
	
	THREAD_LOCK: {
		warn "DEBUG[$tid]:try_lock-print=$Thread_Lock\n";
		lock $Thread_Lock;
		$Thread_Lock = "Locked by $tid print @cmd buffer";
		print @buffer;
	};
	warn "DEBUG[$tid]:unlock-print=$Thread_Lock\n";
	
	return $rc;
}
#----------
# Main
#----------

# Variables a recopier dans chaque thread
my (@jobs_queue, $job_list_ref, $max_workers);

# Traitement pré-threading pour limiter l'espace mémoire
PREPARE_THREADING_OR_NOT_IN_THREAD: {
	# Traitement des options
	require Getopt::Long;
	Getopt::Long->import();
	require Pod::Usage;
	Pod::USage->import();
	
	my (
		$file, @job,
		$help,
		$log,
		$max_process,
	);

	# Initialisation de valeur
	$max_process = 255;
	Getopt::Long::Configure('no_ignore_case');
	GetOptions(
			'file=s'       => \$file,
			'help'         => \$help,
			'job=s'        => \@job,
			'maxprocess=i' => \$max_process,
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
		#      	 nom      => généré automatiquement si absent
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
	$job_list_ref = $parse_job_list->($file) if ($file);
	# Lecture à partir de la ligne de commande
	my $job_id_nb = 0;
	$job_list_ref->{"JOB".$job_id_nb++}->{COMMAND}=$_ foreach (@job);

	my @jobs_list = keys(%{$job_list_ref});

	DEBUG && warn "DEBUG:jobs_list=", Dumper(\@jobs_list), ", job_list_ref=", Dumper($job_list_ref), "\n";

	# Vérification et initialisation
	pod2usage({
		-message => 'No sufficient argument.',
		-exitval => 2,
	}) unless ($job_list_ref);
	
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
# Redirige STDERR => STDOUT, marche???

#-------------
# Démarrage du père qui travaille!!
#-------------
# Evite de charger File::Basename
my ($progname) = ($0 =~ m{([^/]+)$});

# Creation de la session
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$year += 1900;
$mon++;
my $job_session = sprintf('%d-%d-%d:%d:%d:%d', $year, $mon, $mday, $hour, $min, $sec);
print log_msg('info', $progname), "Start session $job_session.\n";

DEBUG && warn "DEBUG:jobs_runqueue=", Dumper(\@jobs_queue);

# Démarrage en mode Threading
my $jobs_queue = Thread::Queue->new();

my $thread_exec = sub {
	my $tid           = threads->self->tid();
	my $jobs_in_error = 0;
	
	my $debug_doit;
	warn "DEBUG[$tid]:start-thread\n";
	JOB_QUEUE: while (my $current_job = $jobs_queue->dequeue()) {
		my $job_run_ref = $job_list_ref->{$current_job};
		$debug_doit++;
		
		warn "DEBUG[$tid]:start-item=$debug_doit\n";
		# Lancement du job
		my $command = $job_run_ref->{COMMAND};
		THREAD_LOCK: {
			#lock $lock_thread;
			print log_msg('info', "job($current_job)", $tid), "job($current_job): Start '$command'\n";
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
					#lock $lock_thread;
					print log_msg('info', "job($current_job/$step)", $tid), "job($current_job/$step): Start '$step'\n";
				}

				unless (exists $job_run_ref->{STEP}->{$step}) {
					print log_msg('error', "job($current_job/$step)", $tid), "job($current_job/$step): Ended step '$step' STATUS=12. Step does not exist\n";
					$rc = 8;
					last STEP;
				}
				$counter++;

				my $cmd = $job_run_ref->{STEP}->{$step}->{command};
				if ($counter > $maxstep) {
					print log_msg('error', "job($current_job/$step)", $tid), "job($current_job/$step): Ended step '$cmd' STATUS=12. Maxstep exceeded '$maxstep'\n";
					$rc = 8;
					last STEP;
				}

				my @logs_step;
				
				if ($job_run_ref->{STEP}->{$step}->{ignore}) {
					$rc = 0;
					print log_msg('info', "job($current_job/$step)", $tid),"job($current_job/$step): Skip step '$cmd'.\n";
				} else {
					my $logs_ref;
					$rc = exec_job("$current_job/$step", $cmd);
				}
		
				$ENV{LBD_JOB_RC}       = $rc; # Pour usage dans les autres scripts
				$ENV{LBD_JOB_PREVIOUS} = $cmd;
	
				DEBUG && warn "DEBUG:Step: step=$current_job/$step, rc=$rc\n";
	
				# Cas d'erreur, $rc != 0, tag de reprise
				print &log_msg('info', "job($current_job/$step)", $tid),"REDOSTEP=$job_session=$current_job=$step\n" if ($rc);

				my $level = (exists $to_global{$rc}) ? $to_global{$rc} : "error"; # Step suivant, fonction du  résultat de la commande
				THREAD_LOCK: {
					#lock $lock_thread;
					print @logs_step;
				}

				$last_level = $level;
				$step = $job_run_ref->{STEP}->{$step}->{$level}; # Next step
			}
			print log_msg($last_level, "job($current_job)", $tid), "job($current_job): Ended 'JOB STEPS' STATUS=$rc\n";

			$job_rc = $rc;
		} else {
			$job_rc = exec_job($current_job, $command);
		}
		
		THREAD_LOCK: { # Pour écrire sereinement 
			#lock $lock_thread;
			if ($job_rc) {
				# Increment le compteur de nombre de job en erreur
				$jobs_in_error++;
				# On le stack dans les piles des jobs pour un redo
				print log_msg('info', $current_job, $tid), "REDO=$job_session=$current_job\n";
			}
			print @logs;
			# Libère le lock en sortant du bloc
		}
		warn "DEBUG[$tid]:end-item=$debug_doit=$current_job\n";
	}
	$jobs_queue->enqueue(undef); # Pour débloquer les autres Threads
	
	warn "DEBUG[$tid]:end-thread\n";
	
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
warn "All workers ready ($max_workers) ...\n";

# Worker créé, on peut lancer les travaux!
warn "Queuing work!\n";
$jobs_queue->enqueue(@jobs_queue);
# Undef débloque la file : cela veut dire que c'est terminé.
$jobs_queue->enqueue(undef);
warn "Queue full, start waiting\n";
# C'est parti, plus qu'à attendre la fin des threads

DEBUG && warn "DEBUG: waiting...\n";
my $jobs_in_error = 0;

my $all_rc = 0;
my @threads = threads->list(threads::all);

JOIN: while (@threads) {
	my $t   = shift @threads;
	my $tid = $t->tid(); 
	
	if ($t->is_joinable()) {
		$jobs_in_error++ if ($t->join());
		
		next JOIN;
	}
	threads->yield();
	push @threads, $t;
}

# Fin de session
print &log_msg('info', $progname), "Ended session $job_session. STATUS=$jobs_in_error\n";

exit $jobs_in_error;

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

