#!/usr/bin/env perl

use 5.032;
use strict;
use warnings;

use File::Slurp qw(read_file write_file);
use File::Spec::Functions qw(catfile);
use File::Path qw(make_path);

use JSON qw();
use YAML::XS qw();
use Template;

use Time::Piece;
use Data::Dump;

use if $^O eq 'MSWin32', 'Win32::Console::ANSI';
use Term::ANSIColor;

no warnings 'experimental::signatures';
use feature 'signatures';

use constant {
    RELEASE_VERSION => "1.5.0-nc",
    RELEASE_DATE    => "2021-09-14",
    COMPOSE_FILE    => 'docker-compose.yml'
};

my %config = do {
    my $isWin32 = $^O eq 'MSWin32';
    my $homeDir = $ENV{NIMBUS_HOME} //
        catfile( ($ENV{HOME} // $ENV{USERPROFILE} // die "Could not determine home directory.\n"), ".nimbusapp" );

    make_path($homeDir) unless -d $homeDir;

    (
        WINDOWS => $isWin32,
        DEFAULT_ORG => "admpresales",
        APPS_CONFIG => $ENV{NIMBUS_CONFIG} // catfile($homeDir, 'apps.json'),
        CACHE => $ENV{NIMBUS_CACHE} // catfile($homeDir, 'cache'),
        DEBUG => 0,     # Be verbose
        FORCE => 0,     # Skip prompts
        QUIET => 0,     # Be quiet
        DAEMON_CONFIG => $isWin32 ? 'C:\ProgramData\Docker\config\daemon.json' : '/etc/docker/daemon.json',
        LOG_FILE => $ENV{NIMBUS_LOG} // catfile($homeDir, 'nimbusapp.log'),
        NL => "\n"
    );
};

my %command = (
    help => sub {
        usage();
        exit scalar @_;
    },
    version => sub {
        info("Release Version: ", RELEASE_VERSION);
        info("Release Date: ", RELEASE_DATE);
    },
    up => prompt_first('CONFIRM_RECREATE', \&docker_app_compose),
    down => prompt_first('CONFIRM_DELETE', \&docker_compose),
    render => \&docker_app,
    inspect => \&docker_app
);

$command{$_} = \&docker_compose for qw( pull start stop restart rm ps logs exec );

# Output functions
# Everything except docker-{compose,app} output goes to STDERR
#    This allows that output to be easily recorded or used in scripts
use subs qw(info debug warn error fatal usage);

sub _log {
    return if $ENV{NIMBUS_INTERNAL};
    my $logLevel = shift;
    my $t = localtime;
    open(my $fh, '>>', $config{LOG_FILE});
    printf $fh "%s %6s %s%s", $t->datetime, $logLevel, join('', @_), $config{NL};
    close($fh);
}

sub _output { print STDERR @_, $config{NL} unless $ENV{NIMBUS_INTERNAL}; }

sub debug   { _log 'DEBUG', @_; _output @_ if $config{DEBUG}; }
sub info    { _log  'INFO', @_; _output @_ unless $config{QUIET}; }
sub warn    { _log  'WARN', @_; _output text_block('LABEL_WARN'), @_; }
sub error   { _log 'ERROR', @_; _output text_block('LABEL_ERROR'), @_; }
sub fatal   { _log 'FATAL', @_; _output text_block('LABEL_ERROR'), @_; exit 1; }
sub usage   { _log 'FATAL', @_; _output @_, $config{NL}, text_block('USAGE'); exit scalar @_; }

# Load some text from the configuration document at the bottom of this file
# This keeps huge blocks of gtext out of the code, which may or may not be useful
sub text_block($name, $params = {}) {
    state $text     = YAML::XS::LoadFile(\*DATA);
    state $template = Template->new(VARIABLES => {
        RED => color('bold red'),
        YELLOW => color('bold yellow'),
        BOLD => color('bold'),
        RESET => color('reset')
    });

    $template->process(\$text->{$name}, $params, \my $output) || die $template->error;
    return $output;
}

sub prompt($label, $params) {
    return if $config{FORCE} || $params->{cmd} eq 'up' && grep { // } $params->{args}->@*;

    print STDERR text_block($label, $params) =~ s/[\n\r]+$//r, " [y/N] ";

    my $result = <STDIN>;
    chomp($result);

    _log 'PROMPT', $label, " = ", $result;

    exit if $result !~ /^y(es)?$/i;
}

sub prompt_first($label, $sub) {
    return sub {
        my $params = $_[1];

        if (nimbusapp($params, 'ps -q')) {
            local $params->{containers} = [ nimbusapp($params, 'ps --service --all') ];
            prompt($label, $params);
        }

        $sub->(@_);        
    };
}

sub nimbusapp($params, @args) {
    my @result = do {
        local $ENV{NIMBUS_INTERNAL} = 1;
        my $a = join ' ', @args;
        qx{perl "$0" "$params->{originalImage}" -q $a}
    };

    if (wantarray) {
        chomp @result;
        return @result;
    }
    else {
        return join '', @result;
    }
}

sub docker_app($cmd, $params, $args) {
    if ($cmd eq 'inspect') {
        my @command = ('docker-app', 'inspect', $params->{fullImage});
        debug("Running: ", join ' ', @command);
        system(@command) or exit $?;
    }
    else { # Render
        my @settings = map { ('-s', $_) } $params->{settings}->@*;
        
        make_path($params->{composeDir}) unless -d $params->{composeDir};

        open(my $compose, '>', $params->{composeFile}) or die "Could not open " . $params->{composeFile} . "\n";

        my @command = ('docker-app', 'render', @settings, $params->{fullImage});
        debug("Running: ", join ' ', @command);
        open(my $app, '-|', @command) or die "Could not run docker-app: $1";

        while (defined(my $line = <$app>)) {
            print $compose $line;
        }

        close($app);
        close($compose);

        if ($cmd eq 'render') {
            print read_file $params->{composeFile};
        }
    }

    return 0;
}

sub docker_compose($cmd, $params, $args) {
    if (! -f $params->{composeFile}) {
        my $rc = docker_app($cmd, $params, $args);
        return $rc if $rc;
    }

    push @$args, '-d' if $cmd eq 'up' && ! grep { $_ eq '--no-start' } @$args;

    my @compose = ( 'docker-compose', '-f', $params->{composeFile}, '-p', $params->{image}, $cmd, @$args );
    debug("Running: ", join ' ', @compose);
    
    # Steffensen change - added this if statement to stop LR agent process for start or up
    if ($cmd eq 'start' || $cmd eq 'up') {
        system "taskkill /IM magentproc.exe /F >nul 2>&1";
    }
    
     system @compose;

    # Steffensen change - added this if statement to start LR agent process for stop or down
    if ($cmd eq 'stop' || $cmd eq 'down') {
        system 1, "C:\\Program Files (x86)\\Micro Focus\\LoadRunner\\launch_service\\bin\\magentproc.exe";
    }
    
       return 0;
}

sub docker_app_compose {
    my $rc = docker_app(@_);
    return $rc if $rc;
    return docker_compose(@_);
}

sub load_app(%params) {
    my $json = JSON::XS->new->utf8->pretty;

    if (-f $config{APPS_CONFIG}) {
        my $jsonstr = read_file( $config{APPS_CONFIG} );
        my $apps = $json->decode($jsonstr);

        if (defined(my $app = $apps->{$params{image}})) {
            $params{$_} ||= $app->{$_} for qw(tag org);
        }
    }

    fatal text_block('VERSION_MISSING', \%params) if not defined $params{tag};

    return %params;
}

sub save_app(%params) {
    my $json = JSON->new->utf8->pretty;
    my $apps;

    if (-f $config{APPS_CONFIG}) {
        $apps = $json->decode( scalar read_file($config{APPS_CONFIG}) );
    }

    $apps->{$params{image}} = {
        map { $_ => $params{$_} } qw(image org tag)
    };

    write_file $config{APPS_CONFIG}, $json->encode($apps);
}

sub get_dns_servers {
    grep { state %seen; !$seen{$_}++ } map { /DNS.*?:\s*(\d.*)/ } qx{netsh interface ip show config};
}

# States:
#   1  STOPPED
#   4  RUNNING
sub wait_for_docker($state) {
    while (1) {
        qx{sc.exe query docker} =~ /^\s* STATE \s* : \s* \d+ \s* (\w+)/imx;
        last if $1 eq $state;
        sleep 1;
    }
}

sub restart_docker {
    qx{sc.exe stop docker};
    wait_for_docker('STOPPED');
    qx{sc.exe start docker};
    wait_for_docker('RUNNING');
}

# Ensure docker networking is set up
# { "dns": [ "192.168.61.2" ] }
if ($config{WINDOWS}) {
    my $json = JSON->new->utf8->pretty;
    my $daemon = -f $config{DAEMON_CONFIG} ? $json->decode( scalar read_file($config{DAEMON_CONFIG}) ) : {};

    if (!defined $daemon->{dns} || @{$daemon->{dns}} == 0) {
        info text_block('DNS_START', {});
        my @dns = get_dns_servers();

        if (@dns) {
            $daemon->{dns} = [ @dns ];
            write_file( $config{DAEMON_CONFIG}, $json->encode($daemon) );
            info text_block('DNS_COMPLETE', { servers => [ @dns ], file => $config{DAEMON_CONFIG} });
            restart_docker();
        } else {
            warn text_block('MISSING_DNS', { file => $config{DAEMON_CONFIG} });
        }
    }
}

sub build_re {
    my $opts = join "|", @_;
    return qr/^($opts)$/;
}

my %re = (
    # Returns org, image, tag
    image => qr{
        ^(?:  (?<org>  .*  )\/ )?      # Optional org
              (?<image> .*? )           # Image
         (?: :(?<tag>   .*  )   )? $    # Optional tag
        }xx,

    # Options
    set => build_re(qw(-s --set)),
    debug => build_re(qw(-d --debug)),
    force => build_re(qw(-f --force)),
    quiet => build_re(qw(-q --quiet)),
    unsupported => build_re(qw(-v -m -p -f --force --preserve-volumes))
);

usage unless @ARGV;
_log 'CMD', join(' ', @ARGV);

my %params = do {
    # First arg, minus any leading dashes
    my $img = shift =~ s/^--?//r;

    # Immediately run nimbusapp [ help|version ]
    if (defined $command{$img}) {
        exit ($command{$img}->() // 0);
    }

    # Not a command, treat it like an image name
    usage "Invalid image name: $img" unless $img =~ $re{image};
    %+;
};

while (@ARGV > 0) {
    my $arg = shift;

    if ($arg =~ $re{set}) {
        push $params{settings}->@*, shift;
    }
    elsif ($arg =~ $re{debug}) {
        $config{DEBUG}++;
    }
    elsif ($arg =~ $re{force}) {
        $config{FORCE}++;
    }
    elsif ($arg =~ $re{quiet}) {
        $config{QUIET}++;
    }
    elsif ($arg =~ $re{unsupported}) {
        fatal 'This version of nimbusapp does not support ', $arg;
    }
    elsif (defined $command{$arg}) {
        %params = load_app(%params);

        for (qw(tag image)) {
            fatal 'Required parameter missing: ', $_ if not defined $params{$_};
        }

        $params{org} //= $config{DEFAULT_ORG};
        $params{fullImage} = sprintf "%s/%s.dockerapp:%s", @params{qw(org image tag)};
        $params{composeDir} = catfile($config{CACHE}, $params{image});
        $params{composeFile} = catfile($params{composeDir}, COMPOSE_FILE);
        $params{cmd} = $arg;
        $params{originalImage} = $params{image};
        $params{args} = [ @ARGV ];

        info 'Using: ', $params{fullImage};

        my $rc = $command{$arg}->($arg, \%params, \@ARGV);
        save_app(%params) if $rc == 0;
        exit $rc;
    }
    else {
        usage "Unknown option: $arg";
    }
}

__DATA__
LABEL_WARN: "[% YELLOW %]WARNING[% RESET %]"
LABEL_ERROR: "[% RED %]ERROR[% RESET %]"

DNS_START: "No Docker DNS configuration found, attempting to configure DNS servers."

DNS_COMPLETE: |
    Docker DNS servers have been configured to use the following addresses:
    [% FOREACH server IN servers %]
        [% server %]
    [% END %]

    Docker DNS settings can be reviewed in [% file %]

MISSING_DNS: |
    No DNS servers found, Docker containers may not be able to communicate with other servers.
    Docker DNS settings can be found in [% file %]

MISSING_VERSION: |
    No version number specified!

    If this is your first time using [% originalImage %], please specify a version number:

    nimbusapp [% originalImage %]:<version_number> [% cmd %]

    The version number you choose will be remembered for future commands.

CONFIRM_DELETE: |
    [% BOLD %]This action will [% RED %]DELETED[% RESET %][% BOLD %] your containers and is [% RED %]IRREVERSIBLE[% RESET %]!
    
    [% BOLD %]You may wish to use [% RESET %]`nimbusapp [% originalImage %] stop'[% BOLD %] to shut down your containers without deleting them[% RESET %]
    
    [% BOLD %]The following containers will be deleted:[% RESET %]
    [% FOREACH item IN containers -%]
        - [% item %]
    [% END -%]

    [% RED %]Do you wish to DELETE these containers?[% RESET %]

CONFIRM_RECREATE: |
    [% BOLD %]This action may cause one or more of your containers to be [% RED %]DELETED[% RESET %][% BOLD %] and [% RED %]RECREATED[% RESET %].
    
    [% BOLD %]Recreating containers is normal when changing their configuration, such as image, tag or ports.[% RESET %]
    
    [% BOLD %]You may wish to use [% RESET %]`nimbusapp [% originalImage %] start'[% BOLD %] to start your existing containers.[% RESET %]
    
    [% C_BOLD %]The following containers may be recreated:[% RESET %]
    [% FOREACH item IN containers -%]
        - [% item %]
    [% END -%]

    [% RED %]Some or all containers may be recreated, do you wish to continue?[% RESET %]

USAGE: |
    Usage: nimbusapp <IMAGE>[:<VERSION>] [OPTIONS] COMMAND [CMD OPTIONS]

    Options:
        IMAGE       The Docker App file you wish to run. If no repository is provided, admpresales is assumed.
        VERSION     The version of the Docker App file you wish to run.
                    Only required the first time a container is created, and will be cached for future use.
        -d, --debug Enable debugging output (use twice for verbose bash commands)
        -f, --force Skip all prompts - Use with caution, this option will happily delete your data without warning
        -s, --set   Enables you to set(override) default arguments
        --version   Print the version of nimbusapp and exit

    Commands:
        down     Stop and remove containers
        help     Prints this help message
        inspect  Shows metadata and settings for a given application
        logs     Shows logs for containers
        ps       Lists containers
        pull     Pull service images
        render   Render the Compose file for the application
        rm       Remove stopped containers
        restart  Restart containers
        start    Start existing containers
        stop     Stop existing containers
        up       Creates and start containers
        version  Prints version information

    Command Options:
        up  --no-start       Create containers without starting them
            --force-recreate Force all containers to be re-created
            --no-recreate    Do not allow any containers to be re-created
    
