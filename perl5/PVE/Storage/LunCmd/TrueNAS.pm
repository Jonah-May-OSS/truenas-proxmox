=pod
=head1 NAME
PVE::Storage::LunCmd::TrueNAS - iSCSI LUN management via TrueNAS REST API

=head1 SYNOPSIS
    PVE::Storage::LunCmd::TrueNAS::run_lun_command(
        $scfg, $timeout, $method, @params
    );

=head1 DESCRIPTION
Implements iSCSI LUN operations (create/delete/list/modify) against
TrueNAS CORE / SCALE using the v1.0 or v2.0 REST API.

=head1 METHODS

=head2 run_lun_command($scfg, $timeout, $method, @params)
Main dispatcher for LUN commands. Returns 1 on success or croaks on failure.

=head2 get_base()
Returns the base path for ZFS volumes (usually '/dev/zvol').

=head2 run_create_lu, run_delete_lu, run_modify_lu, run_list_lu, run_list_extent, run_list_view, run_add_view
Low-level routines for each LUN operation.

=cut

package PVE::Storage::LunCmd::TrueNAS;

use strict;
use warnings;
use Carp qw(croak);
use IO::Socket::SSL;
use REST::Client;
use MIME::Base64 qw(encode_base64);
use JSON::MaybeXS qw(encode_json decode_json);
use PVE::SafeSyslog qw(syslog);

# constants & globals
use constant MAX_LUNS => 255;
our %SERVER_LIST;
our %GLOBAL_CONFIG_LIST;
our $API_VERSION       = 'v1.0';
our $API_METHODS;       # set after version negotiation
our $API_VARS;
our $TRUENAS_VERSION;
our $PRODUCT_NAME;
our $RELEASE_TYPE      = 'Production';

my $DEV_PREFIX         = '';
my $API_PATH           = '/api/v1.0/system/version/';
my $RUNAWAY_PREVENT    = 0;

# API version matrix
my $API_VERSION_MATRIX = {
    'v1.0' => {
        methods => {
            config => { resource => '/api/v1.0/services/iscsi/globalconfiguration/' },
            target => { resource => '/api/v1.0/services/iscsi/target/' },
            extent => {
                resource  => '/api/v1.0/services/iscsi/extent/',
                post_body => {
                    iscsi_target_extent_type => 'Disk',
                    iscsi_target_extent_name => '$name',
                    iscsi_target_extent_disk => '$device',
                },
            },
            targetextent => {
                resource  => '/api/v1.0/services/iscsi/targettoextent/',
                post_body => {
                    iscsi_target => '$target_id',
                    iscsi_extent => '$extent_id',
                    iscsi_lunid  => '$lun_id',
                },
            },
        },
        variables => {
            basename   => 'iscsi_basename',
            lunid      => 'iscsi_lunid',
            extentid   => 'iscsi_extent',
            targetid   => 'iscsi_target',
            extentpath => 'iscsi_target_extent_path',
            extentnaa  => 'iscsi_target_extent_naa',
            targetname => 'iscsi_target_name',
        },
    },
    'v2.0' => {
        methods => {
            config => { resource => '/api/v2.0/iscsi/global' },
            target => { resource => '/api/v2.0/iscsi/target/' },
            extent => {
                resource     => '/api/v2.0/iscsi/extent/',
                delete_body  => { remove => \1, force => \1 },
                post_body    => {
                    type => 'DISK',
                    name => '$name',
                    disk => '$device',
                },
            },
            targetextent => {
                resource     => '/api/v2.0/iscsi/targetextent/',
                delete_body  => { force => \1 },
                post_body    => {
                    target => '$target_id',
                    extent => '$extent_id',
                    lunid  => '$lun_id',
                },
            },
        },
        variables => {
            basename   => 'basename',
            lunid      => 'lunid',
            extentid   => 'extent',
            targetid   => 'target',
            extentpath => 'path',
            extentnaa  => 'naa',
            targetname => 'name',
        },
    },
};

# command dispatch
my %COMMAND_DISPATCH = (
    create_lu   => \&run_create_lu,
    delete_lu   => \&run_delete_lu,
    import_lu   => \&run_create_lu,
    modify_lu   => \&run_modify_lu,
    add_view    => \&run_add_view,
    list_view   => \&run_list_view,
    list_extent => \&run_list_extent,
    list_lu     => sub { my ($s,$t,$m,@p)=@_; return run_list_lu($s,$t,$m,'name',@p) },
);

=head2 get_base
Returns the base ZFS volume path.
=cut
sub get_base { '/dev/zvol' }

=head2 run_lun_command
=cut
sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('info', "run_lun_command: $method(@params)");

    # auth checks
    if ($scfg->{truenas_token_auth}) {
        croak 'Missing truenas_secret' unless defined $scfg->{truenas_secret};
    } else {
        croak 'Missing truenas_user/password'
            unless defined $scfg->{truenas_user} && defined $scfg->{truenas_password};
    }

    # initialize API
    my $host = $scfg->{truenas_apiv4_host}//$scfg->{portal};
    truenas_api_connect($scfg) unless $SERVER_LIST{$host};

    # dispatch
    if (my $cb = $COMMAND_DISPATCH{$method}) {
        return $cb->($scfg, $timeout, $method, @params) || 1;
    }
    croak "Unknown LUN method '$method'";
}

=head2 run_add_view
=cut
sub run_add_view { return 1 }

=head2 run_modify_lu
=cut
sub run_modify_lu {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('debug','run_modify_lu');
    shift @params;  # drop new size
    run_delete_lu($scfg, $timeout, $method, @params);
    run_create_lu($scfg, $timeout, $method, @params);
}

=head2 run_list_view
=cut
sub run_list_view {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('debug','run_list_view');
    return run_list_lu($scfg, $timeout, $method, 'lun-id', @params);
}

=head2 run_list_extent
=cut
sub run_list_extent {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('debug','run_list_extent');
    (my $obj = $params[0]) =~ s/^\Q$DEV_PREFIX//;
    my $luns = truenas_list_lu($scfg);
    return unless exists $luns->{$obj};
    return $luns->{$obj}{ $API_VARS->{extentnaa} };
}

=head2 run_list_lu
=cut
sub run_list_lu {
    my ($scfg, $timeout, $method, $val_type, $obj) = @_;
    syslog('debug',"run_list_lu($val_type)");
    $obj =~ s/^\Q$DEV_PREFIX//;
    my $luns = truenas_list_lu($scfg);
    return unless exists $luns->{$obj};
    my $e = $luns->{$obj};
    return $val_type eq 'lun-id'
        ? $e->{ $API_VARS->{lunid} }
        : $DEV_PREFIX . $e->{ $API_VARS->{extentpath} };
}

=head2 run_create_lu
=cut
sub run_create_lu {
    my ($scfg, $timeout, $method, $lun_path) = @_;
    syslog('info',"run_create_lu($lun_path)");
    my $lun_id = truenas_get_first_available_lunid($scfg);
    croak "Max LUNs (".MAX_LUNS.") exceeded" if $lun_id >= MAX_LUNS;
    croak "LUN '$lun_path' exists"
        if run_list_lu($scfg, $timeout, $method, 'name', $lun_path);

    my $target_id = truenas_get_targetid($scfg);
    croak "Unable to find target id" unless defined $target_id;

    my $extent = truenas_iscsi_create_extent($scfg, $lun_path)
        or croak "create_extent failed";
    truenas_iscsi_create_target_to_extent($scfg, $target_id, $extent->{id}, $lun_id)
        or croak "link creation failed";
    return 1;
}

=head2 run_delete_lu
=cut
sub run_delete_lu {
    my ($scfg, $timeout, $method, $lun_path) = @_;
    syslog('info',"run_delete_lu($lun_path)");
    $lun_path =~ s/^\Q$DEV_PREFIX//;
    my $luns = truenas_list_lu($scfg);
    croak "LUN '$lun_path' not found" unless exists $luns->{$lun_path};
    my $lun = $luns->{$lun_path};

    my $target_id = truenas_get_targetid($scfg);
    croak "Unable to find target id" unless defined $target_id;

    my $t2e = truenas_iscsi_get_target_to_extent($scfg);
    my ($link) = grep {
        $_->{ $API_VARS->{targetid} } == $target_id
        && $_->{ $API_VARS->{lunid}   } == $lun->{ $API_VARS->{lunid} }
        && $_->{ $API_VARS->{extentid} } == $lun->{id}
    } @$t2e;
    croak "Link for LUN '$lun_path' not found" unless $link;

    truenas_iscsi_remove_target_to_extent($scfg, $link->{id})
        or croak "remove link failed";
    truenas_iscsi_remove_extent($scfg, $lun->{id})
        or croak "remove extent failed";
    return 1;
}

# API connection & versioning
sub truenas_api_connect {
    my ($scfg) = @_;
    syslog('info','truenas_api_connect');
    my $scheme = $scfg->{truenas_use_ssl} ? 'https' : 'http';
    my $host   = $scfg->{truenas_apiv4_host}//$scfg->{portal};
    $SERVER_LIST{$host} //= REST::Client->new();
    my $c = $SERVER_LIST{$host};
    $c->setHost("$scheme://$host");
    $c->getUseragent->timeout(10);
    $c->addHeader('Content-Type','application/json');
    if ($scfg->{truenas_token_auth}) {
        syslog('info','Bearer auth');
        $c->addHeader('Authorization','Bearer '.$scfg->{truenas_secret});
    } else {
        syslog('info','Basic auth');
        $c->addHeader('Authorization','Basic '.encode_base64("$scfg->{truenas_user}:$scfg->{truenas_password}", ''));
    }
    if ($scfg->{truenas_use_ssl}) {
        $c->getUseragent->ssl_opts(verify_hostname=>0, SSL_verify_mode=>IO::Socket::SSL::SSL_VERIFY_NONE);
    }

    my $res = $c->GET($API_PATH);
    my $code = $res->responseCode;
    my $ct   = $res->responseHeader('Content-Type');
    if ($RUNAWAY_PREVENT > 2) {
        truenas_api_log_error($c); croak 'recursion limit';
    }
    my $content = $res->responseContent;
    if ($code == 200 && $ct =~ m{^(?:text/plain|application/json)}) {
        ($PRODUCT_NAME, $TRUENAS_VERSION) = content_to_version(\$content);
    } else {
        truenas_api_log_error($c); croak "connect failed $host";
    }

    $API_VERSION = version_to_api($TRUENAS_VERSION);
    $API_METHODS = $API_VERSION_MATRIX->{$API_VERSION}{methods};
    $API_VARS    = $API_VERSION_MATRIX->{$API_VERSION}{variables};

    $GLOBAL_CONFIG_LIST{$host} //= truenas_iscsi_get_globalconfiguration($scfg);
}

=head2 content_to_version($content_ref)
Parses the version string from API output.
=cut
sub content_to_version {
    my ($content_ref) = @_;
    my $text = $$content_ref; $text =~ s/"//g;
    if ($text =~ /TrueNAS(?:-CORE)?[ -]?(\d+\.\d+)/) {
        return ('TrueNAS', $1);
    } elsif ($text =~ /TrueNAS-?SCALE[ -]?(\d+\.\d+)/) {
        return ('TrueNAS-SCALE', $1);
    }
    croak "Unable to parse TrueNAS version from '$text'";
}

=head2 version_to_api($version)
Maps TrueNAS version to API version.
=cut
sub version_to_api {
    my ($v) = @_;
    my ($major) = split /\./, $v;
    return $major >= 12 ? 'v2.0' : 'v1.0';
}

sub truenas_api_call {
    my ($scfg, $method, $path, $data) = @_;
    syslog('info',"API call $method $path");
    croak "Invalid HTTP method '$method'" unless $method =~ /^(?:GET|POST|DELETE)$/;
    my $host = $scfg->{truenas_apiv4_host}//$scfg->{portal};
    my $c    = $SERVER_LIST{$host};
    my $json = defined $data ? encode_json($data) : undef;
    $c->request($method, $path, $json);
}

sub truenas_api_log_error {
    my ($c) = @_;
    $c //= $_[0];
    syslog('error','API error code: ' . $c->responseCode);
    syslog('error','API error content: ' . $c->responseContent);
}

=head2 truenas_iscsi_get_globalconfiguration($scfg)
=cut
sub truenas_iscsi_get_globalconfiguration {
    my ($scfg) = @_;
    truenas_api_call($scfg, 'GET', $API_METHODS->{config}{resource});
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return decode_json($res->responseContent) if $res->responseCode == 200;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_get_extent($scfg)
=cut
sub truenas_iscsi_get_extent {
    my ($scfg) = @_;
    truenas_api_call($scfg, 'GET', $API_METHODS->{extent}{resource} . "?limit=0");
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return decode_json($res->responseContent) if $res->responseCode == 200;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_create_extent($scfg, $lun_path)
=cut
sub truenas_iscsi_create_extent {
    my ($scfg, $lun_path) = @_;
    my $name   = (split m{/}, $lun_path)[-1];
    my $device = $lun_path; $device =~ s{^/dev/}{};
    my %tmpl   = ( name => $name, device => $device );
    my $body   = {};
    while (my ($k,$v) = each %{ $API_METHODS->{extent}{post_body} }) {
        if ($v =~ /^\$(\w+)\$/) {
            $body->{$k} = $tmpl{$1};
        } else {
            $body->{$k} = $v;
        }
    }
    truenas_api_call($scfg, 'POST', $API_METHODS->{extent}{resource}, $body);
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return decode_json($res->responseContent) if $res->responseCode =~ /^(200|201)$/;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_remove_extent($scfg, $extent_id)
=cut
sub truenas_iscsi_remove_extent {
    my ($scfg, $extent_id) = @_;
    my $path = $API_METHODS->{extent}{resource};
    $path .= ($API_VERSION eq 'v2.0') ? "id/" : '';
    $path .= "$extent_id/";
    truenas_api_call($scfg, 'DELETE', $path);
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return 1 if $res->responseCode =~ /^(200|204)$/;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_get_target($scfg)
=cut
sub truenas_iscsi_get_target {
    my ($scfg) = @_;
    truenas_api_call($scfg, 'GET', $API_METHODS->{target}{resource} . "?limit=0");
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return decode_json($res->responseContent) if $res->responseCode == 200;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_get_target_to_extent($scfg)
=cut
sub truenas_iscsi_get_target_to_extent {
    my ($scfg) = @_;
    truenas_api_call($scfg, 'GET', $API_METHODS->{targetextent}{resource} . "?limit=0");
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    if ($res->responseCode == 200) {
        my $arr = decode_json($res->responseContent);
        foreach my $item (@$arr) {
            unless (defined $item->{ $API_VARS->{lunid} }) {
                $item->{ $API_VARS->{lunid} } = 0;
            }
        }
        return $arr;
    }
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_create_target_to_extent($scfg, $target_id, $extent_id, $lun_id)
=cut
sub truenas_iscsi_create_target_to_extent {
    my ($scfg, $target_id, $extent_id, $lun_id) = @_;
    my $body = {};
    while (my ($k,$v) = each %{ $API_METHODS->{targetextent}{post_body} }) {
        if ($v =~ /^\$(\w+)\$/) {
            $body->{$k} = { target_id => \$target_id, extent_id => \$extent_id, lun_id => \$lun_id }->{$1};
        } else {
            $body->{$k} = $v;
        }
    }
    truenas_api_call($scfg, 'POST', $API_METHODS->{targetextent}{resource}, $body);
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return decode_json($res->responseContent) if $res->responseCode =~ /^(200|201)$/;
    truenas_api_log_error();
    return;
}

=head2 truenas_iscsi_remove_target_to_extent($scfg, $link_id)
=cut
sub truenas_iscsi_remove_target_to_extent {
    my ($scfg, $link_id) = @_;
    return 1 if $API_VERSION eq 'v2.0';
    my $path = $API_METHODS->{targetextent}{resource} . "$link_id/";
    truenas_api_call($scfg, 'DELETE', $path);
    my $res = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}};
    return 1 if $res->responseCode =~ /^(200|204)$/;
    truenas_api_log_error();
    return;
}

=head2 truenas_list_lu($scfg)
=cut
sub truenas_list_lu {
    my ($scfg) = @_;
    my $targets   = truenas_iscsi_get_target($scfg) || [];
    my $target_id = truenas_get_targetid($scfg);
    my %lun_hash;
    if (defined $target_id) {
        my $t2e    = truenas_iscsi_get_target_to_extent($scfg) || [];
        my $exts   = truenas_iscsi_get_extent($scfg) || [];
        foreach my $link (@$t2e) {
            next unless $link->{ $API_VARS->{targetid} } == $target_id;
            foreach my $e (@$exts) {
                if ($e->{id} == $link->{ $API_VARS->{extentid} }) {
                    my $lunid = $link->{ $API_VARS->{lunid} };
                    $lunid = 0 unless defined $lunid;
                    $e->{ $API_VARS->{lunid} } = $lunid;
                    $lun_hash{ $e->{ $API_VARS->{extentpath} } } = $e;
                    last;
                }
            }
        }
    }
    return \%lun_hash;
}

=head2 truenas_get_first_available_lunid($scfg)
=cut
sub truenas_get_first_available_lunid {
    my ($scfg) = @_;
    my $target_id = truenas_get_targetid($scfg);
    my @ids;
    foreach my $link (@{ truenas_iscsi_get_target_to_extent($scfg) || [] }) {
        push @ids, $link->{ $API_VARS->{lunid} } if $link->{ $API_VARS->{targetid} } == $target_id;
    }
    my $next = 0;
    foreach my $i (sort {$a <=> $b} @ids) {
        last if $i != $next;
        $next++;
    }
    return $next;
}

=head2 truenas_get_targetid($scfg)
=cut
sub truenas_get_targetid {
    my ($scfg) = @_;
    my $cfg = $GLOBAL_CONFIG_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}} || {};
    foreach my $t (@{ truenas_iscsi_get_target($scfg) || [] }) {
        my $iqn = $cfg->{ $API_VARS->{basename} } . ':' . $t->{ $API_VARS->{targetname} };
        return $t->{id} if $iqn eq $scfg->{target};
    }
    return;
}

1;
