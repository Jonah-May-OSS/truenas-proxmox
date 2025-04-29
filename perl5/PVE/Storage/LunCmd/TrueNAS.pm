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

# Global variable definitions
my $truenas_server_list = undef;           # API connection HashRef using the IP address of the server
my $truenas_rest_connection = undef;       # Pointer to entry in $truenas_server_list
my $truenas_global_config_list = undef;    # IQN HashRef using the IP address of the server
my $truenas_global_config = undef;         # Pointer to entry in $truenas_global_config_list

# constants & globals
use constant MAX_LUNS => 255;                       # Max LUNS per target on the iSCSI server
our %SERVER_LIST;
our %GLOBAL_CONFIG_LIST;
our $API_VERSION    = 'v1.0';
our $TRUENAS_VERSION;
our $PRODUCT_NAME;
our $RELEASE_TYPE   = 'Production';

my $DEV_PREFIX      = '';
my $API_PATH        = '/api/v1.0/system/version/';  # Initial API method for setup
my $RUNAWAY_PREVENT = 0;                            # Recursion prevention variable

# API version matrix
my $API_VERSION_MATRIX = {
    'v1.0' => {
        methods => {
            config => { resource => '/api/v1.0/services/iscsi/globalconfiguration/' },
            target => { resource => '/api/v1.0/services/iscsi/target/' },
            extent => {
                resource => '/api/v1.0/services/iscsi/extent/',
                post_body => {
                    iscsi_target_extent_type => 'Disk',
                    iscsi_target_extent_name => '$name',
                    iscsi_target_extent_disk => '$device',
                },
            },
            targetextent => {
                resource => '/api/v1.0/services/iscsi/targettoextent/',
                post_body => {
                    iscsi_target => '$target_id',
                    iscsi_extent => '$extent_id',
                    iscsi_lunid => '$lun_id',
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
                resource => '/api/v2.0/iscsi/extent/',
                delete_body => { remove => \1, force => \1 },
                post_body => {
                    type => 'DISK',
                    name => '$name',
                    disk => '$device',
                },
            },
            targetextent => {
                resource => '/api/v2.0/iscsi/targetextent/',
                delete_body => { force => \1 },
                post_body => {
                    target => '$target_id',
                    extent => '$extent_id',
                    lunid => '$lun_id',
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

# dispatch for run_lun_command
my %COMMAND_DISPATCH = (
    create_lu   => \&run_create_lu,
    delete_lu   => \&run_delete_lu,
    import_lu   => \&run_create_lu,
    modify_lu   => \&run_modify_lu,
    add_view    => \&run_add_view,
    list_view   => \&run_list_view,
    list_extent => \&run_list_extent,
    list_lu     => sub { my ($s,$t,$m,@p)=@_; run_list_lu($s,$t,$m,'name',@p) },
);

# return the base path for zvols
sub get_base { '/dev/zvol' }

# main entry point
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

    my $host = $scfg->{truenas_apiv4_host} // $scfg->{portal};
    truenas_api_check($scfg) if !exists $SERVER_LIST{$host};

    if (my $cb = $COMMAND_DISPATCH{$method}) {
        return $cb->($scfg, $timeout, $method, @params);
    }

    croak "Unknown LUN method '$method'";
}

sub run_add_view { '' }

#
# a modify_lu occur by example on a zvol resize. we just need to destroy and recreate the lun with the same zvol.
# Be careful, the first param is the new size of the zvol, we must shift params
#
sub run_modify_lu {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('info','run_modify_lu');
    shift @params;
    run_delete_lu($scfg, $timeout, $method, @params);
    run_create_lu($scfg, $timeout, $method, @params);
}

sub run_list_view {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('info','run_list_view');
    run_list_lu($scfg, $timeout, $method, 'lun-id', @params);
}

sub run_list_extent {
    my ($scfg, $timeout, $method, @params) = @_;
    syslog('info','run_list_extent');
    (my $obj = $params[0]) =~ s/^\Q$DEV_PREFIX//;
    my $luns = truenas_list_lu($scfg);
    return $luns->{$obj}{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{extentnaa} }
        if exists $luns->{$obj};
    return;
}

sub run_list_lu {
    my ($scfg, $timeout, $method, $val_type, $obj) = @_;
    syslog('info',"run_list_lu($val_type)");
    $obj =~ s/^\Q$DEV_PREFIX//;
    my $luns = truenas_list_lu($scfg);
    return unless exists $luns->{$obj};
    my $e = $luns->{$obj};
    if ($val_type eq 'lun-id') {
        return $e->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{lunid} };
    }
    return $DEV_PREFIX . $e->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{extentpath} };
}

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
    '';
}

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
        $_->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{targetid} } == $target_id
        && $_->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{lunid}   } == $lun->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{lunid} }
        && $_->{ $API_VERSION_MATRIX->{$API_VERSION}{variables}{extentid} } == $lun->{id}
    } @$t2e;
    croak "Link for LUN '$lun_path' not found" unless $link;

    truenas_iscsi_remove_target_to_extent($scfg, $link->{id})
        or croak "remove link failed";
    truenas_iscsi_remove_extent($scfg, $lun->{id})
        or croak "remove extent failed";
    '';
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

    if ($RUNAWAY_PREVENT>2) {
        truenas_api_log_error($c);
        croak 'recursion limit';
    } elsif ($code==200 && $ct=~m{^(?:text/plain|application/json)}) {
        $RUNAWAY_PREVENT=0;
    } elsif ($code==302) {
        $RUNAWAY_PREVENT++;
        $API_PATH=~s/v1\.0/v2\.0/;
        $API_VERSION='v2.0';
        return truenas_api_connect($scfg);
    } elsif ($code==307) {
        $RUNAWAY_PREVENT++;
        $scfg->{truenas_use_ssl}=1;
        return truenas_api_connect($scfg);
    } else {
        truenas_api_log_error($c);
        croak "connect failed $host";
    }
    $GLOBAL_CONFIG_LIST{$host} //= truenas_iscsi_get_globalconfiguration($scfg);
}

sub truenas_api_check {
    my ($scfg) = @_;
    syslog('info','truenas_api_check');
    truenas_api_connect($scfg);
    my $content = $SERVER_LIST{$scfg->{truenas_apiv4_host}//$scfg->{portal}}->responseContent;
    # parse version string from $content, set $PRODUCT_NAME, $TRUENAS_VERSION, $RELEASE_TYPE
    # select API_VERSION based on version
    $API_VERSION_MATRIX->{$API_VERSION} or croak "Unsupported API version";
}

sub truenas_api_call {
    my ($scfg,$method,$path,$data)=@_;
    syslog('info',"API call $method $path");
    croak "Invalid HTTP method '$method'" unless $method=~m{^(?:GET|POST|DELETE)$};
    my $host= $scfg->{truenas_apiv4_host}//$scfg->{portal};
    my $c   = $SERVER_LIST{$host};
    my $json = defined $data ? encode_json($data) : undef;
    $c->request($method,$path,$json);
}

sub truenas_api_log_error {
    my ($c)=@_;
    $c //= $_[0];
    syslog('error','API error code: '.$c->responseCode);
    syslog('error','API error content: '.$c->responseContent);
}

#
#
#
sub truenas_iscsi_get_globalconfiguration {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    truenas_api_call($scfg, 'GET', $truenas_api_methods->{'config'}->{'resource'}, $truenas_api_methods->{'config'}->{'get'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : target_basename=" . $result->{$truenas_api_variables->{'basename'}});
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Returns a list of all extents.
# http://api.truenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-extent-
#
sub truenas_iscsi_get_extent {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    truenas_api_call($scfg, 'GET', $truenas_api_methods->{'extent'}->{'resource'} . "?limit=0", $truenas_api_methods->{'extent'}->{'get'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Create an extent on TrueNas
# http://api.truenas.org/resources/iscsi/index.html#create-resource
# Parameters:
#   - target config (scfg)
#   - lun_path
#
sub truenas_iscsi_create_extent {
    my ($scfg, $lun_path) = @_;

    syslog("info", (caller(0))[3] . " : called with (lun_path=$lun_path)");

    my $name = $lun_path;
    $name  =~ s/^.*\///; # all from last /

    my $pool = $scfg->{'pool'};
    # If TrueNAS-SCALE the slashes (/) need to be converted to dashes (-)
    if ($product_name eq "TrueNAS-SCALE") {
        $pool =~ s/\//-/g;
        syslog("info", (caller(0))[3] . " : TrueNAS-SCALE slash to dash conversion '" . $pool ."'");
    }
    $name  = $pool . ($product_name eq "TrueNAS-SCALE" ? '-' : '/') . $name;
    syslog("info", (caller(0))[3] . " : " . $product_name . " extent '". $name . "'");

    my $device = $lun_path;
    $device =~ s/^\/dev\///; # strip /dev/

    my $post_body = {};
    while ((my $key, my $value) = each %{$truenas_api_methods->{'extent'}->{'post_body'}}) {
        $post_body->{$key} = ($value =~ /^\$.+$/) ? eval $value : $value;
    }

    truenas_api_call($scfg, 'POST', $truenas_api_methods->{'extent'}->{'resource'}, $post_body);
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200 || $code == 201) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", "TrueNAS::API::create_extent(lun_path=" . $result->{$truenas_api_variables->{'extentpath'}} . ") : successful");
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Remove an extent by it's id
# http://api.truenas.org/resources/iscsi/index.html#delete-resource
# Parameters:
#    - scfg
#    - extent_id
#
sub truenas_iscsi_remove_extent {
    my ($scfg, $extent_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (extent_id=$extent_id)");
    truenas_api_call($scfg, 'DELETE', $truenas_api_methods->{'extent'}->{'resource'} . (($truenas_api_version eq "v2.0") ? "id/" : "") . "$extent_id/", $truenas_api_methods->{'extent'}->{'delete_body'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200 || $code == 204) {
        syslog("info", (caller(0))[3] . "(extent_id=$extent_id) : successful");
        return 1;
    } else {
        truenas_api_log_error();
        return 0;
    }
}

#
# Returns a list of all targets
# http://api.truenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-target-
#
sub truenas_iscsi_get_target {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    truenas_api_call($scfg, 'GET', $truenas_api_methods->{'target'}->{'resource'} . "?limit=0", $truenas_api_methods->{'target'}->{'get'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Returns a list of associated extents to targets
# http://api.truenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-targettoextent-
#
sub truenas_iscsi_get_target_to_extent {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    truenas_api_call($scfg, 'GET', $truenas_api_methods->{'targetextent'}->{'resource'} . "?limit=0", $truenas_api_methods->{'targetextent'}->{'get'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        # If 'iscsi_lunid' is undef then it is set to 'Auto' in TrueNAS
        # which should be '0' in our eyes.
        # This gave Proxmox 5.x and TrueNAS 11.1 a few issues.
        foreach my $item (@$result) {
            if (!defined($item->{$truenas_api_variables->{'lunid'}})) {
                $item->{$truenas_api_variables->{'lunid'}} = 0;
                syslog("info", (caller(0))[3] . " : change undef iscsi_lunid to 0");
            }
        }
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Associate a TrueNas extent to a TrueNas Target
# http://api.truenas.org/resources/iscsi/index.html#post--api-v1.0-services-iscsi-targettoextent-
# Parameters:
#   - target config (scfg)
#   - TrueNas Target ID
#   - TrueNas Extent ID
#   - Lun ID
#
sub truenas_iscsi_create_target_to_extent {
    my ($scfg, $target_id, $extent_id, $lun_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (target_id=$target_id, extent_id=$extent_id, lun_id=$lun_id)");

    my $post_body = {};
    while ((my $key, my $value) = each %{$truenas_api_methods->{'targetextent'}->{'post_body'}}) {
        $post_body->{$key} = ($value =~ /^\$.+$/) ? eval $value : $value;
    }

    truenas_api_call($scfg, 'POST', $truenas_api_methods->{'targetextent'}->{'resource'}, $post_body);
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200 || $code == 201) {
        my $result = decode_json($truenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . "(target_id=$target_id, extent_id=$extent_id, lun_id=$lun_id) : successful");
        return $result;
    } else {
        truenas_api_log_error();
        return undef;
    }
}

#
# Remove a Target to extent by it's id
# http://api.truenas.org/resources/iscsi/index.html#delete--api-v1.0-services-iscsi-targettoextent-(int-id)-
# Parameters:
#    - scfg
#    - link_id
#
sub truenas_iscsi_remove_target_to_extent {
    my ($scfg, $link_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (link_id=$link_id)");

    if ($truenas_api_version eq "v2.0") {
        syslog("info", (caller(0))[3] . "(link_id=$link_id) : V2.0 API's so NOT Needed...successful");
        return 1;
    }

    truenas_api_call($scfg, 'DELETE', $truenas_api_methods->{'targetextent'}->{'resource'} . (($truenas_api_version eq "v2.0") ? "id/" : "") . "$link_id/", $truenas_api_methods->{'targetextent'}->{'delete_body'});
    my $code = $truenas_rest_connection->responseCode();
    if ($code == 200 || $code == 204) {
        syslog("info", (caller(0))[3] . "(link_id=$link_id) : successful");
        return 1;
    } else {
        truenas_api_log_error();
        return 0;
    }
}

#
# Returns all luns associated to the current target defined by $scfg->{target}
# This method returns an array reference like "truenas_iscsi_get_extent" do
# but with an additionnal hash entry "iscsi_lunid" retrieved from "truenas_iscsi_get_target_to_extent"
#
sub truenas_list_lu {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $targets   = truenas_iscsi_get_target($scfg);
    my $target_id = truenas_get_targetid($scfg);

    my %lun_hash;
    my $iscsi_lunid = undef;

    if(defined($target_id)) {
        my $target2extents = truenas_iscsi_get_target_to_extent($scfg);
        my $extents        = truenas_iscsi_get_extent($scfg);

        foreach my $item (@$target2extents) {
            if($item->{$truenas_api_variables->{'targetid'}} == $target_id) {
                foreach my $node (@$extents) {
                    if($node->{'id'} == $item->{$truenas_api_variables->{'extentid'}}) {
                        if ($item->{$truenas_api_variables->{'lunid'}} =~ /(\d+)/) {
                            if (defined($node)) {
                                $node->{$truenas_api_variables->{'lunid'}} .= "$1";
                                $lun_hash{$node->{$truenas_api_variables->{'extentpath'}}} = $node;
                            }
                            last;
                        } else {
                            syslog("warn", (caller(0))[3] . " : iscsi_lunid did not pass tainted testing");
                        }
                    }
                }
            }
        }
    }
    syslog("info", (caller(0))[3] . " : successful");
    return \%lun_hash;
}

#
# Returns the first available "lunid" (in all targets namespaces)
#
sub truenas_get_first_available_lunid {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $target_id      = truenas_get_targetid($scfg);
    my $target2extents = truenas_iscsi_get_target_to_extent($scfg);
    my @luns           = ();

    foreach my $item (@$target2extents) {
        push(@luns, $item->{$truenas_api_variables->{'lunid'}}) if ($item->{$truenas_api_variables->{'targetid'}} == $target_id);
    }

    my @sorted_luns =  sort {$a <=> $b} @luns;
    my $lun_id      = 0;

    # find the first hole, if not, give the +1 of the last lun
    foreach my $lun (@sorted_luns) {
        last if $lun != $lun_id;
        $lun_id = $lun_id + 1;
    }

    syslog("info", (caller(0))[3] . " : $lun_id");
    return $lun_id;
}

#
# Returns the target id on TrueNas of the currently configured target of this PVE storage
#
sub truenas_get_targetid {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $targets   = truenas_iscsi_get_target($scfg);
    my $target_id = undef;

    foreach my $target (@$targets) {
        my $iqn = $truenas_global_config->{$truenas_api_variables->{'basename'}} . ':' . $target->{$truenas_api_variables->{'targetname'}};
        if($iqn eq $scfg->{target}) {
            $target_id = $target->{'id'};
            last;
        }
    }
    syslog("info", (caller(0))[3] . " : successful : $target_id");
    return $target_id;
}


1;
