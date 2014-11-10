#!/usr/bin/perl -w
# Marcin Gryszkalis <mg@fork.pl>
# https://github.com/marcin-gryszkalis/rebellion

my $VERSION = '0.5';

use strict;
use warnings;

use POSIX qw/SIGHUP strftime/;
use WWW::Curl::Easy;
use WWW::Curl::Form;

use threads (
    # override with env. PERL5_ITHREADS_STACK_SIZE
     'stack_size' => 64*1024, # 128 was to much for 300 browsers on x61
     'exit' => 'threads_only',
     );

use threads::shared;
# use forks;
# use forks::shared;

use Thread::Queue;
# use Event::Lib;
use Data::Dumper;
use URI::Escape;
use File::Slurp;

my $DEBUG_NO_BURL = 0;
my $DEBUG_NO_DELAY = 0;
my $DEBUG_ONE_SHOT = 0;
my $DEBUG_ALWAYS_SAVE_VERIFICATION_LOG = 0;

# global config, defaults
my %cfg = (
    logfile => './sparky.log',
    sparkytee => 0,
    startdelay => 1,
    scenario => undef,
    skippages => undef,
    duration => 60,
    tests => 1,
    sourceip => undef,
);

my @status :shared;
my @round :shared;


my $gen_dowod_prefix = 'BBD';
my $gen_dowod_seed :shared = 0;


my $rebels = 0;

my @def_headers = ();
my %def_variables = ();
my $def_variables_per_fox;
my @def_verifynegs = ();
my %def_delays = ();
my @varfiles = ();
my @varfiles_names = ();

my $stackfiles;
my @stackfiles_names = ();

my @scenario_base = ();
my @scenario = ();
# my $skippages = '';
# my $browsers = 1;
# my @foxies = ();
# my $duration = 600;
# my $tests = undef;
# my $rate = undef;
# my @army = ();
# my @src_ip = ();
#

my $war_is_over  :shared = 0;

my $devnull;

my $curl;

# Signals:

$SIG{PIPE} = 'IGNORE';


# options

use Getopt::Std;
our ($opt_c, $opt_h, $opt_V, $opt_l, $opt_d, $opt_b, $opt_p, $opt_o, $opt_a);
sub VERSION_MESSAGE() { print "$VERSION\n"; }
sub HELP_MESSAGE()
{
print "Usage: rebellion.pl [-hV] [-l log file] -c config-file
    -c config file\t\tMain config file
    -l log file\t\tSparky logger file
    -p http://host\t\tproxy defnition
    -d\t\tno delays
    -b\t\tno static elements (b-url)
    -o\t\tone shot
    -a\t\talways save verification logs
    -h\t\tthis help
    -V\t\tversion info
";
}

getopts('c:hl:Vbdop:a');
if ($opt_h) { HELP_MESSAGE(); exit; }
if ($opt_V) { VERSION_MESSAGE(); exit; }
if ($opt_d) { $DEBUG_NO_DELAY = 1; }
if ($opt_b) { $DEBUG_NO_BURL = 1; }
if ($opt_o) { $DEBUG_ONE_SHOT = 1; }
if ($opt_a) { $DEBUG_ALWAYS_SAVE_VERIFICATION_LOG = 1; }
if ($opt_p) { $cfg{proxy} = $opt_p; }


# # === return channel for main thread
my $queue_re = Thread::Queue->new();

# hashref of queues
my $queues_varlist;

# ================ sparky logger stuff
my $queue_sparky = Thread::Queue->new();


sub now()
{
    my @t = localtime time;
    return sprintf("%4d-%02d-%02d %02d:%02d:%02d", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub thread_sparky
{
    print STDERR "SPARKY:Alive\n";
    $cfg{logfile} = $opt_l if defined $opt_l;
    open(L, ">$cfg{logfile}") or die("cannot create logfile ($cfg{logfile}): $!");
    $queue_re->enqueue("OK");
    while (my $msg = $queue_sparky->dequeue())
    {
        chomp $msg;
#        print STDERR "SPARKY:msg($msg)\n";
        my ($mode, $msg) = split/\s+/, $msg, 2;
        last if $msg eq 'END';
        my $date = now();
        print L "$date $msg\n";
        print STDERR "$date $msg\n" if ($cfg{sparkytee} || $mode eq 'HIGH');
    }
    close(L);
}

sub LOG($)
{
    $queue_sparky->enqueue("LOW ".shift);
}

sub MSG($)
{
    $queue_sparky->enqueue("HIGH ".shift);
}


sub randxy($$)
{
    my $a = shift;
    my $b = shift;
    return int($a + rand($b - $a + 1));
}

# === Generators
my $last_pesel = '';
sub gen_pesel()
{
    # http://wipos.p.lodz.pl/zylla/ut/pesel.html

    my @wagi = qw{1 3 7 9 1 3 7 9 1 3};

    my $pesel = sprintf("%02d%02d%02d%03d%d", 
        randxy(50,90),
        randxy(1,12),
        randxy(1,28),
        randxy(1,999),
        randxy(0,4)*2 + 1); # even = female, odd = male

    my @c = split //, $pesel;
    my $sum = 0;
    for (my $i = 0; $i < 10; $i++)
    {
        my $x = $c[$i] * $wagi[$i];
        $sum += $x;
    }

    my $mod = (10 - ($sum % 10)) % 10;
    $last_pesel = "$pesel$mod";
    return $last_pesel;
}

sub gen_date_from_last_pesel
{
    $last_pesel =~ /^(..)(..)(..)/;
    return sprintf("%04d-%02d-%02d", $1 + 1900, $2 ,$3);
}

sub gen_dowod()
{
    # http://pl.wikipedia.org/wiki/Dow%C3%B3d_osobisty_w_Polsce
    my @wagi = qw{7 3 1 0 7 3 1 7 3};

    $gen_dowod_seed++;

    my $do = sprintf("%s%06d", $gen_dowod_prefix, $gen_dowod_seed);
    my @c = split //, $do;
    my $sum =
        $wagi[0] * (ord($c[0])-55) +
        $wagi[1] * (ord($c[1])-55) +
        $wagi[2] * (ord($c[2])-55) +
        $wagi[3] * $c[3] + # ctrl, will be 0 as wagi[3]==0
        $wagi[4] * $c[4] +
        $wagi[5] * $c[5] +
        $wagi[6] * $c[6] +
        $wagi[7] * $c[7] +
        $wagi[8] * $c[8];

    my $mod = $sum % 10;
    return sprintf("%s%d%05d", $gen_dowod_prefix, $mod, $gen_dowod_seed);
}

sub gen_random_text($)
{
    my $len = shift;
    my @chars=('a'..'z');
    my $v = "";
    foreach (1..$len)
    {
        $v .= $chars[rand @chars];
    }
    return $v;
}

sub gen_email()
{
    return gen_random_text(10).'@'.gen_random_text(10).'.pl';
}

sub gen_random_number($$)
{
    my $min = shift;
    my $max = shift;
    return sprintf("%d", rand($max - $min + 1) + $min);
}

sub gen_firstname
{
    my @names = qw{
Piotr Krzysztof Andrzej Jan Tomasz Marcin Marek Grzegorz Adam Zbigniew Jerzy Tadeusz Mateusz Dariusz Mariusz Wojciech Ryszard Jakub Henryk Robert Kazimierz Jacek Maciej Kamil
Anna Maria Katarzyna Agnieszka Barbara Krystyna Ewa Zofia Teresa Magdalena Joanna Janina Monika Danuta Jadwiga Aleksandra Halina Irena Beata Marta Dorota Helena Karolina Jolanta Iwona Marianna Natalia
};

    return $names[rand($#names)-1];
}

sub gen_lastname
{
    my @names = qw{
Nowak Kowalski Lewandowski Kowalczyk Jankowski Wojciechowski Kwiatkowski Kaczmarek Mazur Krawczyk Piotrowski Grabowski Nowakowski Michalski Nowicki Adamczyk Dudek Wieczorek Majewski Olszewski Jaworski Malinowski Pawlak Witkowski
};

    return $names[rand($#names)-1];
}


sub gen_city
{
    my @names = qw{
Warszawa Szczecin Bydgoszcz Lublin Katowice Gdynia Radom Sosnowiec Kielce Gliwice Olsztyn Tychy Opole Koszalin Kalisz Legnica
};

    return $names[rand($#names)-1];
}

sub gen_list($)
{
    my $qn = shift;
    my $a = $queues_varlist->{$qn}->dequeue();
    if (!defined $a)
    {
        MSG "PROBLEM:Queue($qn) is empty";
        return '0'; # oh well
    }
    else
    {
        LOG "VARLIST($qn)=($a)";
        $queues_varlist->{$qn}->enqueue($a); # store it back, so it doesn't dry
    }
    return $a;
}

sub gen_zipcode
{
    return sprintf("%02d-%03d", int rand(100), int rand(1000))
}

# http://pl.wikipedia.org/wiki/Vehicle_Identification_Number
# 17-chars
# TMB AH6NH8 D4042851
sub gen_vin
{
    return sprintf("TMBAH6NH8%08d", int rand(99999999))
}

# =============================================================================
# xxx REBELS xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# =============================================================================

my $body = undef;
my $body_h = undef; # file handle to $body

sub init_curl($)
{
    my $curl = shift;

    $curl->setopt(CURLOPT_NOSIGNAL, 1);
    # TODO notfound $curl->setopt(CURLOPT_SSLVERSION, CURL_SSLVERSION_SSLv3);
    $curl->setopt(CURLOPT_SSL_VERIFYPEER, 0);
    $curl->setopt(CURLOPT_SSL_VERIFYHOST, 0);

    # wywala bledy dla http kodow >= 400:
    $curl->setopt(CURLOPT_FAILONERROR, 0);
    # we;ll do parsing ourself (TODO: why?)
    $curl->setopt(CURLOPT_HEADER, 1);

    # for debug
#    $curl->setopt(CURLOPT_VERBOSE, 1);

    $curl->setopt(CURLOPT_FOLLOWLOCATION, 1);
    $curl->setopt(CURLOPT_AUTOREFERER, 1);
    $curl->setopt(CURLOPT_MAXREDIRS, 64);

    # check
    $curl->setopt(CURLOPT_FORBID_REUSE, 0);

    # move to config
    $curl->setopt(CURLOPT_CONNECTTIMEOUT, 60);

    $curl->setopt(CURLOPT_POSTFIELDSIZE, -1); # curl will take care ### TODO:  backport change from rebel.c

    # curl->setopt(curl, CURLOPT_COOKIESESSION, 1);
    $curl->setopt(CURLOPT_COOKIEFILE, "");

    if (defined $cfg{proxy})
    {
        $curl->setopt(CURLOPT_PROXY, $cfg{proxy});
        # TODO notfound $curl->setopt(CURLOPT_PROXYTYPE, CURLPROXY_HTTP);
        # curl->setopt(curl, CURLOPT_PROXYTYPE, CURLPROXY_HTTP_1_0);
        # curl->setopt(curl, CURLOPT_HTTPPROXYTUNNEL, 1);
    }


    if (defined $cfg{sourceip})
    {
        $curl->setopt(CURLOPT_INTERFACE, $cfg{sourceip});
    }

        # CURLOPT_MAX_SEND_SPEED_LARGE
        # CURLOPT_MAX_RECV_SPEED_LARGE

        # other config?
        # - CURLOPT_INTERFACE
        # - http auth

    return $curl;
}

sub reset_curl($)
{
    my $curl = shift;
    $curl->cleanup();
    # $curl = undef;
    $curl = new WWW::Curl::Easy;
    $curl = init_curl($curl);
    return $curl
}

sub setup_fox($)
{
    my $id = shift;
    my $fox = undef;
    $fox->{status} = 'start';
    $fox->{line} = -1; # reference to source
    $fox->{round} = 0;
    $fox->{variables} = ();
    $fox->{variables}->{variable_placeholder} = "placeholder";
    $fox->{id} = $id;
#    $fox->{ip} = $src_ip[$id%($#src_ip+2)] if $#src_ip >= 0;

    @scenario = @scenario_base;

    return $fox;
}

sub setup_stack_variables($)
{
    my $fox = shift;

    # get next from stackfiles
    for my $variable (@stackfiles_names)
    {
        my $var = shift @{$stackfiles->{$variable}};
        die "stackfile ($variable) too short" unless $var;
        chomp $var;
        redo if $var =~ /(^\s*$|^#)/;
        $fox->{variables}->{$variable} = $var;

        LOG "STACKFILE($fox->{id}:$variable)=($var)"; 
    }

    return $fox;
}

sub reset_scenario($)
{
    my $fox = shift;
    my $id = $fox->{id};
    my $save_round = $fox->{round} + 1;

    LOG "REBEL($fox->{id}:$fox->{line}):RESET SCENARIO";

    if (exists $fox->{fallback}) # mostly an ugly copy :(
    {

        my $url = $fox->{fallback};
        my $post = undef;
        my $upload = undef;
        my $curlf = undef;

        if ($url =~ /^\s*(\S+)\s+POST\s+(\S+)/)
        {
            $url = $1;
            $post = $2;
            $fox->{post} = $post; # just to remember
        }

        if ($url =~ /^\s*(\S+)\s+UPLOAD\s+(.*)/)
        {
            $url = $1;
            $upload = $2;
            $curlf = WWW::Curl::Form->new;
            MSG "UP($upload)";

            my @upfields = split/\s+/, $upload;
            while (@upfields)
            {
                my $a = shift @upfields;
                my $b = shift @upfields;
                MSG "XF($a)->($b)";
                if (-f $b)
                {
                    my $mt = `file --mime-type '$b'` || 'text/plain';
                    chomp $mt;
                    $curlf->formaddfile($b, $a, $mt);
                    MSG "UPLOAD($a -> $b [$mt])";
                }
                else
                {
                    $curlf->formadd($a, $b);
                }

            }

            $fox->{upload} = $upload; # just to remember
        }


        $url = $fox->{base}."/$url" unless $url =~ m{^https?://};
        $url =~ s{([^:])/+}{$1/}g; # remove multiple /////

        $fox->{url} = $url;
        $curl->setopt(CURLOPT_WRITEDATA, $devnull);
        $curl->setopt(CURLOPT_HTTPGET, 1); # reset to GET, will be overwritten later
        $curl->setopt(CURLOPT_POST, 0);

        $curl->setopt(CURLOPT_URL, $url);
        # fprintf(stderr, "F%d:URL:PAGEID(%s):URL(%s)\n", id, pageid, realurl);

        if ($post)
        {
            $curl->setopt(CURLOPT_POST, 1);
            $curl->setopt(CURLOPT_COPYPOSTFIELDS, $post);
        }

        if ($upload)
        {
            $curl->setopt(CURLOPT_POST, 1);
            $curl->setopt(CURLOPT_HTTPPOST, $curlf);
        }

        $curl->setopt(CURLOPT_HTTPHEADER, \@def_headers);
        my $cpr = $curl->perform();

        LOG "REBEL($fox->{id}:$fox->{line}):FALLBACK:".
            "URL($url)".
            ($post ? ":POST($post)" : "").
            ($upload ? ":UPLOAD($upload)" : "");
    }


    $fox = setup_fox($id);

    $fox->{id} = $id;

    $fox->{round} = $save_round;
    $fox->{status} = 'start';

    $round[$id] = $save_round;
    $status[$id] = 'start';

    if (defined $def_variables_per_fox)
    {
        for (keys %{$def_variables_per_fox})
        {
            $fox->{variables}->{$_} = $def_variables_per_fox->{$_}; # just to make them show
        }
    }

    $fox = setup_stack_variables($fox);

    if ($war_is_over || $DEBUG_ONE_SHOT)
    {
        LOG "REBEL($fox->{id}:0):END-OF-WAR";
        $fox->{status} = 'finished';
        $status[$id] = 'finished';
    }


    $curl = reset_curl($curl);

    return $fox;
}

my $verlognum = 0;
sub verification_log($$$)
{
    my $fox = shift;
    my $reason = shift;
    my $vn = shift;

    my $orygbody = $fox->{body} // 'EMPTY-BODY';
    delete $fox->{body};

    my $body = '';
    my $headers = ''; my $copyheaders = 1;
    for my $l (split/[\r\n]+/,$orygbody)
    {
        if ($copyheaders)
        {
            if ($l =~ /^\S+:\s+\S+/ || $l =~ /^\s*$/ || $l =~ /^HTTP\/1.[01]\s+\d\d\d/)
            {
                $headers .= "$l\n";
            }
            else
            {
                $body .= "$l\n";
                $copyheaders = 0;
            }
        }
        else
        {
            $body .= "$l\n";
        }
    }

    $verlognum++;
    my $vlnumx = sprintf "%04d", $verlognum;
    my $fnumx = sprintf "%04d", $fox->{id};
    my $vlogf = "verification.$fnumx.$vlnumx.$vn.log.html";

    open(V, ">dbg/$vlogf") or die "cannot create verification log: $!";

    print V "<h2>$fox->{page}</h2>\n";
    print V "<h2>$fox->{url}</h2>\n";
    my $vnow = strftime("%F %T", localtime);
    print V "<h2>$vnow</h2><hr>\n";
    print V "<h2>$reason [thread $fox->{id} at line $fox->{line}]</h2><hr>\n";
    print V "<pre style='font-size: 10px;'>\n".(Dumper $fox), "\n</pre>\n<hr>\n";
    print V "<pre style='font-size: 10px; white-space: pre-wrap; '>\n$headers\n</pre>\n<hr>\n";

    # disable popup escape
    #    if(top!=self)top.location.href=location.href;
    #    if (top === self){window.location = '/'; }
    $body =~ s/top[ !=]+self/false/g;

    print V $body;

    close(V);

    $fox->{body} = $orygbody;

    # print V
    #     "VERFAIL:$reason\n",
    #     (Dumper $fox),
    #     "\n\n";

}

sub writedata_callback
{
    my ($chunk, $handle) = @_;
    $body .= $chunk;
    return length $chunk;
}

sub thread_rebel
{
    my $id = shift;

    $status[$id] = 'start';
    $round[$id] = 0;

    my $fox = setup_fox($id);

    # read varfiles
    for my $varfile (@varfiles)
    {
        my @vf = read_file($varfile) or die("cannot open varfile($varfile): $!");
        @vf = grep {!/^#/ } grep {!/^\s*$/} @vf;
        my $varname = shift @varfiles_names;
        my $var = $vf[$id];
        die("varfile ($varname) too short") unless $var;
        chomp $var;
        $fox->{variables}->{$varname} = $var;
        LOG "VARFILE($id:$varname)=($var)";
    }

    my %tmph = %{$fox->{variables}};
    $def_variables_per_fox = \%tmph;

    $fox = setup_stack_variables($fox);

    # prepare curl
    $curl = new WWW::Curl::Easy;
    $curl = init_curl($curl);
    $curl = reset_curl($curl);

    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_URL, '');

    my $start_delay = int(rand($cfg{startdelay})+1);

    LOG "REBEL($id:X) Start (delay: $start_delay)";
    $queue_re->enqueue($id);
    sleep($start_delay);



    # === loop =====================================
    my $skippages_active = 0;
    my $skippages_skipto = undef;

    while (1)
    {

        last if $fox->{status} eq 'finished';

        my $vlvn = $cfg{verification_log_variable};
        my $vlv = exists $fox->{variables}->{$vlvn} ? "$vlvn=$fox->{variables}->{$vlvn}" : "-";
        my $vlvx = exists $fox->{variables}->{$vlvn} ? $fox->{variables}->{$vlvn} : "-";

        my $sline = shift @scenario;
        if (not defined $sline) # end of scenario
        {
            LOG "REBEL($fox->{id}:0):END-OF-ROUND";
            $skippages_active = 0;

            $fox = reset_scenario($fox);

            next;
        }

        $fox->{line} = $sline->{line};

        next if ($skippages_active and $sline->{k} ne 'page');

        if ($sline->{k} eq 'skipto')
        {
            if ($sline->{v} eq 'END')
            {
                LOG "REBEL($fox->{id}:$fox->{line}):SKIPTO(END)";
                # $fox->{lineact} = $#scenario + 10; # skip past end of scenario, it'll got hit above
                # die "not implemented with new auto-burl stuff and no lineact ";
                # next;
    
                $fox = reset_scenario($fox);
                next;
            }
            elsif ($sline->{v} =~  m/^(\S+)\s*$/)
            {
                my $target = $1;
                $skippages_active = 1;
                $skippages_skipto = $target;
                LOG "REBEL($fox->{id}:$fox->{line}):SKIPTO(ALWAYS:$target)";
                next;
            }
            elsif ($sline->{v} =~  m/^RND(\d+)\s+(\S+)/)
            {
                my $rnd = $1;
                my $target = $2;
                if (int(rand(100)) < $rnd)
                {
                    $skippages_active = 1;
                    $skippages_skipto = $target;
                    LOG "REBEL($fox->{id}:$fox->{line}):SKIPTO(RANDOM:$rnd:$target:YES)";
                }
                else
                {
                    LOG "REBEL($fox->{id}:$fox->{line}):SKIPTO(RANDOM:$rnd:$target:NO)";
                }

                next;
            }
            else
            {
                MSG "REBEL($fox->{id}:$fox->{line}):SKIPTO(SYNTAX ERROR:$sline->{v})";
            }
        }

        if ($sline->{k} eq 'verify' || $sline->{k} eq 'verifyneg')
        {
            if (not defined $fox->{body})
            {
                MSG "REBEL($fox->{id}:$fox->{line}:$vlv):ERROR:Verification Failed - body empty";
                verification_log($fox, "body empty", $vlvx);
                $fox = reset_scenario($fox);
                next;
            }

            my $patt = $sline->{v};
            my $verify = 1;
            if ($patt eq 'DEFAULT')
            {
                verification_log($fox, "DEFAULT", $vlvx);
                foreach my $vdef (@def_verifynegs)
                {
                    $patt = $vdef;
                    $verify = !($fox->{body} =~ m!$patt!s);
                    $patt = "DEFAULT:$patt"; # for reporting
                    # print STDERR "DEFAULT:$patt\n";
                    last unless $verify;
                }
            }
            else
            {
                $verify = ($fox->{body} =~ m!$patt!s);
                $verify = !$verify if  $sline->{k} eq 'verifyneg';
            }

            if (not $verify)
            {
                MSG "REBEL($fox->{id}:$fox->{line}:$vlv):ERROR:Verification Failed ($patt)";
                verification_log($fox,"verification:$patt", $vlvx);
                $fox = reset_scenario($fox);
            }
            next;
        }

        if ($sline->{k} eq 'var' || $sline->{k} =~ /^var\@(\d+)$/)
        {
            my $occurence = 0;
            if ($sline->{k} =~ /^var\@(\d+)$/)
            {
                $occurence = $1;
            }

            my @vx = split(/\s+/, $sline->{v}, 2);
            my $patt = $vx[1];
            #print STDERR "PATTV($patt)\n";
            my $match = ($fox->{body} =~ m!$patt!s);
            if ($match)
            {
                if ($occurence > 0)
                {
                    my @matches = ($fox->{body} =~ m!$patt!g);
                    if (@matches)
                    {
                        # my $vchosen = $matches[rand @matches];
                        my $vchosen = $matches[$occurence - 1];

                        if ($vchosen)
                        {
                            $fox->{variables}->{$vx[0]} = $vchosen;
                            LOG "REBEL($fox->{id}:$fox->{line}):VARIABLE:VAR($vx[0]\@$occurence=$1)";
                        }
                        else
                        {
                            MSG "REBEL($fox->{id}:$fox->{line}:$vlv):ERROR:Variable ($vx[0]\@$occurence) occurence not found ($patt)";
                            verification_log($fox, "$vx[0]\@$occurence occurence not found:$patt", $vlvx);
                            $fox = reset_scenario($fox);
                        }
                    }
                    else
                    {
                        MSG "REBEL($fox->{id}:$fox->{line}:$vlv):ERROR:Variable ($vx[0]\@$occurence) not found ($patt)";
                        verification_log($fox, "$vx[0]\@$occurence not found:$patt", $vlvx);
                        $fox = reset_scenario($fox);
                    }

                }
                else
                {
                    $fox->{variables}->{$vx[0]} = $1;
                    LOG "REBEL($fox->{id}:$fox->{line}):VARIABLE:VAR($vx[0]=$1)";
                }
            }
            else
            {
                # more fixes to come
                $fox->{body} =~ s/&quot;/"/g;
                $fox->{body} =~ s/&apos;/'/g;
                $fox->{body} =~ s/&amp;/&/g;
                $fox->{body} =~ s/&lt;/</g;
                $fox->{body} =~ s/&gt;/>/g;
                $fox->{body} =~ s/&nbsp;/ /g;

                $match = ($fox->{body} =~ m!$patt!s);
                if ($match)
                {
                    $fox->{variables}->{$vx[0]} = $1;
                    LOG "REBEL($fox->{id}:$fox->{line}):VARIABLE:VAR($vx[0]=$1)";
                }
                else
                {

                    MSG "REBEL($fox->{id}:$fox->{line}:$vlv):ERROR:Variable ($vx[0]) not found ($patt)";
                    verification_log($fox, "$vx[0] not found:$patt", $vlvx);
#                    print V "VERFAIL($patt):\n", (Dumper $fox), "\n\n";
#                    close(V);
                    $fox = reset_scenario($fox);
                }


            }
            next;
        }

        # TODO copied from new leader.pl - not tested
        if ($sline->{k} =~ 'multivar' )
        {
            my $body = $fox->{body};
            my @vx = split(/\s+/, $sline->{v}, 2);
            my $v = $vx[0];
            if ($v =~ m/(\S+)\[(.*)\]\[(.*)\]/)
            {
                $v = $1;
                my $vfrom = $2;
                my $vto = $3;

                if ($body =~ m!$vfrom(.*?)$vto!)
                {
                    $body = $1;
                }
            }
            my $patt = $vx[1];
            #print STDERR "PATTV($patt)\n";
            my @matches = ($body =~ m!$patt!g);
            if (@matches)
            {
                my $vchosen = $matches[rand @matches];
                $fox->{variables}->{$v} = $vchosen;

                LOG "FOX($fox->{id}:$fox->{line}):MULTIVARIABLE:VAR($vx[0]=$v FROM ".join('|',@matches).")\n";
            }
            else
            {
                LOG "FOX($fox->{id}:$fox->{line}):ERROR:MultiVariable ($v) not found ($patt) - reset scenario\n";
                verification_log($fox, "MULTIVARIABLE($patt)", 'USERNAME');
                $fox = reset_scenario($fox);
            }
            next;
        }


        if ($sline->{k} eq 'autoburl' && !$DEBUG_NO_BURL)
        {
            my @burls = ($fox->{body} =~ m/(?:src|href)=["']([^"'']+?\.(?:png|jpe?g|gif|ico|css|js))/gi);
            for my $burl (@burls)
            {
                LOG "REBEL($fox->{id}:$fox->{line}):AUTO-BURL:$burl";
                my $sc;
                $sc->{k} = 'burl';
                $sc->{v} = $burl;
                $sc->{line} = "$fox->{line}-autoburl";
                unshift(@scenario, $sc);
            }
        }

        # if not var or verify then remove page from memory
        $fox->{body} = undef;
        close($body_h) if defined $body_h;

        if ($sline->{k} eq 'base')
        {
            $fox->{base} = $sline->{v};
            LOG "REBEL($fox->{id}:$fox->{line}):BASE($fox->{base})";
            next;
        }

        if ($sline->{k} eq 'fallback')
        {
            $fox->{fallback} = $sline->{v};
            LOG "REBEL($fox->{id}:$fox->{line}):FALLBACK($fox->{fallback})";
            next;
        }

        if ($sline->{k} eq 'define')
        {
            my @v = split/\s+/, $sline->{v}, 2;
            $fox->{variables}->{$v[0]} = $v[1];
            next;
        }

        if ($sline->{k} eq 'delay')
        {
            my @v = ();
            if ($sline->{v} =~ m/(\d+)\s+(\d+)/)
            {
                @v = ($1, $2);
            }
            else
            {
                if (exists $def_delays{$sline->{v}})
                {
                    @v = split/\s+/, $def_delays{$sline->{v}}, 2;
                }
                else
                {
                    MSG "WARNING: unknown delay definition ($sline->{v}), setting to NONE";
                    @v = (0,0);
                }
            }


            $fox->{status} = 'delay';
            $status[$id] = 'delay';

            my $d = ($DEBUG_NO_DELAY || $sline->{v} eq 'NONE') ? 0 : int(rand($v[1]-$v[0]+1)+$v[0]); # 10-20: rand(20-10+1)+10 = rand(11)+10 = [0..10]+10 = [10..20]
            LOG "REBEL($fox->{id}:$fox->{line}):DELAY($d)";

            sleep($d) if $d > 0; # here's the delay
            next;
        }

        if ($sline->{k} eq 'page')
        {
            $sline->{v} =~ s/^\s+//;
            $sline->{v} =~ s/\s+$//;
            $sline->{v} =~ s/\s+/ /;

            $fox->{page} = $sline->{v};
            $fox->{pageid} = $sline->{v};
            $fox->{pageid} =~ s/\s+.*//; # first word is id

            LOG "REBEL($fox->{id}:$fox->{line}):PAGE($fox->{pageid}):################################## $sline->{v} #####";

            if (defined $cfg{skippages} && $cfg{skippages} ne '' && $fox->{pageid} =~ m/$cfg{skippages}/)
            {
                LOG "REBEL($fox->{id}:$fox->{line}):SKIP-SKIPPAGES($fox->{pageid})";
                $skippages_active = 1;
                next;
            }

            if ($skippages_active)
            {
                if (defined $skippages_skipto && $fox->{pageid} ne $skippages_skipto)
                {
                    LOG "REBEL($fox->{id}:$fox->{line}):SKIP-SKIPTO($fox->{pageid}:$skippages_skipto)";
                    next;
                }

                $skippages_active = 0;
                $skippages_skipto = undef;
                next;
            }

            next;
        }

        if ($sline->{k} =~ /^b?url$/)
        {
            $fox->{status} = $sline->{k};
            $status[$id] = $sline->{k};

            my $url = $sline->{v};
            my $post = undef;
            my $upload = undef;
            my $curlf = undef;

            if ($url =~ /^\s*(\S+)\s+POST\s+(\S+)/)
            {
                $url = $1;
                $post = $2;
            }

            if ($url =~ /^\s*(\S+)\s+UPLOAD\s+(.*)/)
            {
                $url = $1;
                $upload = $2;

            }


            $url = $fox->{base}."/$url" unless $url =~ m{^https?://};
            $url =~ s{([^:])/+}{$1/}g; # remove multiple /////

            # setup variables
            for (keys %{$fox->{variables}})
            {
                my $k = $_;
                my $v = $fox->{variables}->{$k};
                $v = uri_escape($v) unless $k =~ /^NOENC:(.*)/;

#               print STDERR "VAR($k = $v)\n";
                $url =~ s/\Q{$k}\E/$v/g;
                $post =~ s/\Q{$k}\E/$v/g if $post;
                $upload =~ s/\Q{$k}\E/$v/g if $upload;
            }

            for (keys %def_variables)
            {
                my $k = $_;
                my $v = $def_variables{$k};
                $v = uri_escape($v) unless $k =~ /^NOENC:(.*)/;

#                print STDERR "VAR($k = $v)\n";
                $url =~ s/\Q{$k}\E/$v/g;
                $post =~ s/\Q{$k}\E/$v/g if $post;
                $upload =~ s/\Q{$k}\E/$v/g if $upload;
            }

            my $defvpf = $def_variables_per_fox->{$fox->{id}};
            for (keys %{$defvpf})
            {
                my $k = $_;
                my $v = $defvpf->{$k};
                $v = uri_escape($v) unless $k =~ /^NOENC:(.*)/;

#                print STDERR "VAR($k = $v)\n";
                $url =~ s/\Q{$k}\E/$v/g;
                $post =~ s/\Q{$k}\E/$v/g if $post;
                $upload =~ s/\Q{$k}\E/$v/g if $upload;
            }

            for (0..9)
            {
                my $k = "RANDOM$_";

                my $len = 10;
                my @chars=('a'..'z');
                my $v="R$_";
                $v = "Rnd"; # VW - cannot have numbers in names!
                foreach (1..$len)
                {
                    $v .= $chars[rand @chars];
                }

#                print STDERR "VAR($k = $v)\n";
                $url =~ s/\Q{$k}\E/$v/g;
                $post =~ s/\Q{$k}\E/$v/g if $post;
                $upload =~ s/\Q{$k}\E/$v/g if $upload;
            }

            # generators
            # TODO add them for upload
            $url  =~ s/{:TEXT\((\d+)\)}/gen_random_text($1)/ge;
            $post =~ s/{:TEXT\((\d+)\)}/gen_random_text($1)/ge if $post;

            $url  =~ s/{:NUMBER\((\d+),(\d+)\)}/gen_random_number($1,$2)/ge;
            $post =~ s/{:NUMBER\((\d+),(\d+)\)}/gen_random_number($1,$2)/ge if $post;

            $url  =~ s/{:FIRSTNAME}/gen_firstname()/ge;
            $post =~ s/{:FIRSTNAME}/gen_firstname()/ge if $post;

            $url  =~ s/{:LASTNAME}/gen_lastname()/ge;
            $post =~ s/{:LASTNAME}/gen_lastname()/ge if $post;

            $url  =~ s/{:LIST\((\S+)\)}/gen_list($1)/ge;
            $post =~ s/{:LIST\((\S+)\)}/gen_list($1)/ge if $post;

            $url  =~ s/{:PESEL}/gen_pesel()/ge;
            $post =~ s/{:PESEL}/gen_pesel()/ge if $post;

            $url  =~ s/{:DATE_FROM_LAST_PESEL}/gen_date_from_last_pesel()/ge;
            $post =~ s/{:DATE_FROM_LAST_PESEL}/gen_date_from_last_pesel()/ge if $post;

            $url  =~ s/{:VIN}/gen_vin()/ge;
            $post =~ s/{:VIN}/gen_vin()/ge if $post;

            $url  =~ s/{:ZIPCODE}/gen_zipcode()/ge;
            $post =~ s/{:ZIPCODE}/gen_zipcode()/ge if $post;

            $url  =~ s/{:CITY}/gen_city()/ge;
            $post =~ s/{:CITY}/gen_city()/ge if $post;

            $url  =~ s/{:EMAIL}/gen_email()/ge;
            $post =~ s/{:EMAIL}/gen_email()/ge if $post;

            $url  =~ s/{:DOWOD}/gen_dowod()/ge;
            $post =~ s/{:DOWOD}/gen_dowod()/ge if $post;

            my $v = uri_escape(strftime("%F", localtime));
            $url =~ s/{:DATE}/$v/g;
            $post =~ s/{:DATE}/$v/g if $post;

            $v = uri_escape(strftime("%T", localtime));
            $url =~ s/{:TIME}/$v/g;
            $post =~ s/{:TIME}/$v/g if $post;

            $v = uri_escape(strftime("%F %T", localtime));
            $url =~ s/{:DATETIME}/$v/g;
            $post =~ s/{:DATETIME}/$v/g if $post;

            $v = time();
            $url =~ s/{:UNIXTIME}/$v/g;
            $post =~ s/{:UNIXTIME}/$v/g if $post;

# TODO commented out in leader.pl too...
#             # multivariables
#             for (keys %{$fox->{multivariables}})
#             {
#                 my $k = $_;

# #               print STDERR "VAR($k = $v)\n";
#                 $url =~ s/\Q{$k}\E/$v/g;
#                 $post =~ s/\Q{$k}\E/$v/g if $post;
#             }

            my $bulk = 0;
            # burl cache
            if ($sline->{k} eq 'burl')
            {
                if ($fox->{cache}->{$url} || $DEBUG_NO_BURL == 1)
                {
                    LOG
                        "REBEL($fox->{id}:$fox->{line}):BURL:".
                        "URL($url) CACHED";
                    next;
                }
                $fox->{cache}->{$url} = 1;
                $bulk = 1;
            }

            $fox->{url} = $url;
            $fox->{post} = $post; # just to remember
            $fox->{upload} = $upload; # just to remember

            if ($bulk)
            {
#                 $curl->setopt(CURLOPT_WRITEFUNCTION, undef);
                $curl->setopt(CURLOPT_WRITEDATA, $devnull);
            }
            else
            {

                $curl->setopt(CURLOPT_WRITEFUNCTION, \&writedata_callback);
                $body = '';
                open ($body_h, ">", \$body);
                $curl->setopt(CURLOPT_WRITEDATA, $body_h);
            }

            $curl->setopt(CURLOPT_HTTPGET, 1); # reset to GET, will be overwritten later
            $curl->setopt(CURLOPT_POST, 0);

            $curl->setopt(CURLOPT_URL, $url);
            # fprintf(stderr, "F%d:URL:PAGEID(%s):URL(%s)\n", id, pageid, realurl);

            if ($post)
            {
                $curl->setopt(CURLOPT_POST, 1);
                $curl->setopt(CURLOPT_COPYPOSTFIELDS, $post);
            }

            if ($upload)
            {
                $curlf = WWW::Curl::Form->new;
                my @upfields = split/\s+/, $upload;
                while (@upfields)
                {
                    my $a = shift @upfields;
                    my $b = shift @upfields;
                    if (-f $b)
                    {
                        my $mt = `file --mime-type '$b'` || 'text/plain';
                        chomp $mt;
                        $curlf->formaddfile($b, $a, $mt);
                        MSG "UPLOAD($a -> $b [$mt])";
                    }
                    else
                    {
                        $curlf->formadd($a, $b);
                    }

                }
                
                $curl->setopt(CURLOPT_POST, 1);
                $curl->setopt(CURLOPT_HTTPPOST, $curlf);

            }

            $curl->setopt(CURLOPT_HTTPHEADER, \@def_headers);

            #my $curl_errorstr;
            #$curl->setopt(CURLOPT_ERRORBUFFER, $curl_errorstr);
            #$curl_errorstr = "-" unless defined $curl_errorstr;


            # fprintf(stderr, "F%d:ATTACK:PAGEID(%s)\n", id, pageid);

            my $cpr = $curl->perform();

#            my $cookies = "Cookie: ";
#            for (keys %{$fox->{cookies}})
#            {
#                $cookies .= "$_=$fox->{cookies}->{$_}; ";
#            }
#            $rebel->{socket}->print("$cookies\n");
            my $responsecode = $curl->getinfo(CURLINFO_RESPONSE_CODE);
            my $curl_errorstr = $cpr != 0 ? $curl->strerror($cpr) : '-';
            my $curl_os_errno = $curl->getinfo(CURLINFO_OS_ERRNO);
            if ($cpr != 0)
            {
                MSG sprintf(
                        "REBEL(%d:%d):ERROR:PAGEID(%s):CURL(%d):ERRNO(%ld):HTTP(%ld):ERRMSG(%s)",
                        $id, $fox->{line},
                        $fox->{pageid}, $cpr, $curl_os_errno, $responsecode, $curl_errorstr);
            }
            elsif ($responsecode >= 400 && !$bulk)
            {
                MSG sprintf(
                        "REBEL(%d:%d):HTTP_ERROR(%ld):PAGEID(%s)",
                        $id, $fox->{line},$responsecode,$fox->{pageid});

            }

            my $totaltime = $curl->getinfo(CURLINFO_TOTAL_TIME);
            my $conntime = $curl->getinfo(CURLINFO_CONNECT_TIME);
            my $appconntime = $curl->getinfo(CURLINFO_APPCONNECT_TIME);
            my $pttime = $curl->getinfo(CURLINFO_PRETRANSFER_TIME);
            my $sttime = $curl->getinfo(CURLINFO_STARTTRANSFER_TIME);
            my $redirtime = $curl->getinfo(CURLINFO_REDIRECT_TIME);
            my $downsize = $curl->getinfo(CURLINFO_SIZE_DOWNLOAD);
            my $upsize = $curl->getinfo(CURLINFO_SIZE_UPLOAD);
            my $reqsize = $curl->getinfo(CURLINFO_REQUEST_SIZE);

            my $pfix = ($cpr == 0) ? "OK!" : "ERR";

            LOG sprintf(
                        "REBEL(%d:%s):CALL-%s:PAGEID(%s):%s:CURL(%d:%ld:%s):HTTP(%ld):TT(%.3f):CT(%.3f):AT(%.3f):PT(%.3f):ST(%.3f):RT(%.3f):DS(%.1f):US(%.1f):RS(%.1f):%s",
                        $id,$fox->{line},
                        ($bulk ? "B" : "")."URL:",
                        $fox->{pageid},
                        $pfix,
                        $cpr, $curl_os_errno, $curl_errorstr,
                        $responsecode, # long
                        $totaltime,  # dbl
                        $conntime, # dbl
                        $appconntime, # dbl
                        $pttime, # dbl
                        $sttime, # dbl
                        $redirtime, # dbl
                        $downsize, # dbl
                        $upsize, # dbl
                        $reqsize, # dbl
                        $url
                        );

            if (!$bulk)
            {
                $fox->{body} = $body;
                $body = undef;
            }

            LOG
                "REBEL($fox->{id}:$fox->{line}):".
                ($bulk ? "B" : "")."URL:".
                "URL($url)".
                ($post ? ":POST($post)" : "");

            if ($cpr != 0 && !$bulk)
            {
                verification_log($fox, "CURL Error($cpr -- $curl_errorstr)", $vlvx);
                $fox = reset_scenario($fox);
            }
            elsif ($responsecode >= 400 && !$bulk)
            {
                verification_log($fox, "HTTP Error($responsecode)", $vlvx);
                $fox = reset_scenario($fox);
            }

            #####################################
            ### DBG
            #####################################
            elsif (!$bulk && $DEBUG_ALWAYS_SAVE_VERIFICATION_LOG) 
            {
                verification_log($fox, "OK", $vlvx);
            }
            ####################################


            next;
        }

    }

    sleep(2);

    LOG "REBEL($id:X) Retired";
}


# =============================================================================
# === MAIN part (Lee) =========================================================
# =============================================================================


open($devnull, ">/dev/null") or die("cannot open /dev/null for write");

# === read config =============================================================


# create threads that are needed
my $th_sparky = threads->create({'stack_size' => 128*4096},\&thread_sparky); # just for case - bigger stack_size
$queue_re->dequeue(); # wait for sparky's confirmation
sleep(1); # allow time for sparky setup
MSG "Rebellion v$VERSION";
sleep(1);

# === read config =============================================================

#x my $fighter_squads = 0;
if (!defined $opt_c) { die("config file not specified"); }
open(C, "<$opt_c") or die("cannot open config file ($opt_c): $!");
while (<C>)
{
    chomp;
    next if /^\s*#/;
    next if /^\s*$/;

    if (/^header\s*=\s*(.+)/)
    {
        push(@def_headers, $1);
        next;
    }

    if (/^variable\s*=\s*(\S+)\s+(.+)/) # can have spaces!
    {
        my $vv = $2;
        $vv =~ s/\s+$//; # but not at the end
        $def_variables{$1} = $2;
        next;
    }

    if (/^verifyneg\s*=\s*(\S+)/)
    {
        push(@def_verifynegs, $1);
        next;
    }

    if (/^delaydef\s*=\s*(\S+)\s+(\S+)\s+(\S+)/)
    {
        $def_delays{$1} = "$2 $3";
        next;
    }

    if (/^varfile\s*=\s*(\S+)\s+(\S+)/)
    {
        push(@varfiles_names, $1);
        push(@varfiles, $2);
        next;
    }

    if (/^stackfile\s*=\s*(\S+)\s+(\S+)/)
    {
        my $vn = $1; my $fn = $2;
        push(@stackfiles_names, $vn);
        my @sf = read_file($fn) or die "cannot read stackfile($2)";
        $stackfiles->{$vn} = \@sf;

        next;
    }

    if (/^varlist\s*=\s*(\S+)\s+(\S+)/)
    {
        my $vln = $1;
        $queues_varlist->{$vln} = Thread::Queue->new();
        open(VL, $2);
        while (<VL>)
        {
            chomp;
            next if /^#/;
            next if /^\s*$/;
            $queues_varlist->{$vln}->enqueue($_);
        }
        close(VL);
        next;
    }

    # unspecified options
    if (/^(\S+)\s*=\s*(\S+)/)
    {
        $cfg{$1} = $2;
    }
}
close(C);

$rebels = $cfg{browsers};

MSG "Configuration:";
MSG Dumper \%cfg;
#x my $threads_per_squad = int($browsers / $fighter_squads);
#x $threads_per_squad++ while ($threads_per_squad * $fighter_squads < $browsers);

if (!defined $cfg{scenario}) { die("scenario file not specified"); }
open(C, "<$cfg{scenario}") or die("cannot open scenario file ($cfg{scenario}): $!");
my $scenline = 0;
while (<C>)
{
    chomp;
    $scenline++;

    next if /^\s*[#;]/;
    next if /^\s*$/;

    die "scenario syntax error[$scenline]: $_" unless /=/;

    my $sc;
    my @ss = split /=/, $_, 2;

    $ss[0] =~ s/^\s+//;
    $ss[0] =~ s/\s+$//;
    $ss[1] =~ s/^\s+//;
    $ss[1] =~ s/\s+$//;

    $sc->{k} = $ss[0];
    $sc->{v} = $ss[1];
    $sc->{line} = $scenline;
    push(@scenario_base, $sc);
}
close(C);



# === start the army ============================================================
my $d = 0;
my @th_rebels = ();
my $rebel_id; # loop counter
for $rebel_id (0..$rebels-1)
{
    push(@th_rebels, threads->create(\&thread_rebel, $rebel_id));
}

# wait for rebels to be ready
my $live_rebels = 0;
my $war_start_time = time();

while ($live_rebels < $rebels)
{
    $rebel_id = $queue_re->dequeue();
    $live_rebels++;
    MSG "REBELLION:rebel($rebel_id) reported for duty ($live_rebels of $rebels)";
}


# use Devel::FindGlobals;
# print STDERR print_globals_sizes();

# === main loop =================================================================
my $loop = 0;
while (1)
{
    $loop++;

    my %statuses = ();
    my $statusesrep;

    for $rebel_id (0..$rebels-1)
    {
        $statuses{$status[$rebel_id]}++;
    }

    my @statuskeys = qw/start url burl delay finished/;

    for (@statuskeys)
    {
        $statusesrep .= exists $statuses{$_} ? sprintf("%8s=%04d ", $_, $statuses{$_}) : ' ' x (8 + 1 + 5 + 1);
    }
    $statusesrep =~ s/\s+$//;

    my $totalrounds = 0;
    for $rebel_id (0..$rebels-1)
    {
        $totalrounds += $round[$rebel_id];
    }

    MSG "REBELLION:L($loop):R($totalrounds):S(subdf): $statusesrep";


    if (!$war_is_over && $totalrounds >= $cfg{tests})
    {
        $war_is_over = 'tests';
        MSG "REBELLION:war-is-over(tests)";
    }


    if (!$war_is_over && time() - $war_start_time > $cfg{duration})
    {
        $war_is_over = 'time';
        MSG "REBELLION:war-is-over(time)";
    }

    # finish dead bodies
    while ($war_is_over && $live_rebels > 0)
    {
        MSG "REBELLION:burying dead bodies ($live_rebels left)";
        for my $r (@th_rebels)
        {
            if ($r->is_joinable())
            {
                $r->join();
                $live_rebels--;
            }
        }
        sleep(1);
    }

    last if $live_rebels == 0;

    sleep(1);
}

MSG "REBELLION:FINISHED";
LOG 'END'; # messenger quits last
$th_sparky->join();
sleep(3);

