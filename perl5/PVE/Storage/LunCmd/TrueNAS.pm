package PVE::Storage::LunCmd::TrueNAS;

use strict;
use warnings;
use Carp qw(croak);
use JSON::MaybeXS qw(decode_json encode_json);
use PVE::Tools qw(run_command);
use PVE::SafeSyslog qw(syslog);

# SSH configuration
our $ID_RSA_PATH = '/etc/pve/priv/zfs';
our @SSH_OPTS    = ('-o', 'BatchMode=yes');

# Return storage prefix (used by ZFSPlugin)
sub get_base {
    return 'zvol';
}

# Helper: execute SSH command, capture and log stdout/stderr via syslog
sub _debug_cmd {
    my ($cmd_ref, $timeout) = @_;
    my $cmd_str = join(' ', @$cmd_ref);
    syslog('debug', "SSH CMD: $cmd_str");

    # Buffers to collect output
    my $stdout = '';
    my $stderr = '';

    # run_command with outfunc/errfunc to capture streams
    my $exit = run_command(
        $cmd_ref,
        timeout => $timeout,
        outfunc => sub { $stdout .= shift },
        errfunc => sub { $stderr .= shift },
    );

    # Normalize into a HASHref
    my $res = {
        exitcode => $exit,
        out      => $stdout,
        err      => $stderr,
    };

    syslog('debug', "SSH exit code: $exit");
    syslog('debug', "SSH stdout: $stdout");
    syslog('debug', "SSH stderr: $stderr");

    return $res;
}


# Main dispatcher
sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;
    if (ref($scfg->{portal}) eq 'ARRAY') {
        $scfg->{portal} = $scfg->{portal}[0];
    }
    croak "TrueNAS: missing portal" unless $scfg->{portal};
    syslog('info', "TrueNAS LUN cmd: $method(@params)");

    return _create_lu($scfg, $timeout,  $params[0]) if $method =~ /^(create|import)_lu$/;
    return _delete_lu($scfg, $timeout,  $params[0]) if $method eq 'delete_lu';
    if ($method eq 'modify_lu') {
        _delete_lu($scfg, $timeout, $params[0]);
        return _create_lu($scfg, $timeout, $params[0]);
    }
    return _list_lu($scfg, $timeout,    $params[0]) if $method eq 'list_lu';
    return _list_extent($scfg, $timeout, $params[0]) if $method eq 'list_extent';
    return _list_naa($scfg, $timeout,    $params[0]) if $method eq 'list_naa';
    return 1 if $method eq 'add_view';
    croak "TrueNAS: unknown method '$method'";
}

# Create extent and map it
sub _create_lu {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;

    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    # derive dataset and name
    (my $zpath = $zvol) =~ s{^/dev/}{};
    (my $name  = $zpath) =~ s{^.*/}{};

    # build and exec create extent command
    my $payload = "'{\"name\":\"$name\",\"type\":\"DISK\",\"disk\":\"$zpath\"}'";
    syslog('debug', "_create_lu payload: $payload");
    my @cmd = ('/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host, "midclt", "call", "iscsi.extent.create", $payload);
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: extent.create failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    # decode JSON and extract the new extent ID
    my $data = decode_json($res->{out} || '[]');
    my $eid;
    if (ref($data) eq 'ARRAY') {
        $eid = $data->[0]{id};
    }
    elsif (ref($data) eq 'HASH') {
        $eid = $data->{id};
    }
    else {
        croak "TrueNAS: unexpected JSON from extent.create: $res->{out}";
    }
    syslog('debug', "_create_lu extracted extent ID: $eid");

    # map the extent to the target
    my $tid = _query_target_id($scfg, $timeout);
    my $map = "'{\"target\":$tid,\"extent\":$eid}'";
    syslog('debug', "_create_lu map: $map");
    @cmd = ('/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host, "midclt", "call", "iscsi.targetextent.create", $map);
    _debug_cmd(\@cmd, $timeout);

    return $eid;
}

# Delete extent and unmap LUNs
sub _delete_lu {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    for my $teid (@{ _list_targetextent_ids($scfg, $timeout, $zvol) }) {
        my $up = encode_json({ id => $teid });
        syslog('debug', "_delete_lu unmap: $up");
        my $cmd = qq(midclt call iscsi.targetextent.delete '$up');
        _debug_cmd(['/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host, $cmd], $timeout);
    }

    my $eid = _query_extent_id($scfg, $timeout, $zvol);
    my $dp  = encode_json({ id => $eid });
    syslog('debug', "_delete_lu delete: $dp");
    my $cmd = qq(midclt call iscsi.extent.delete '$dp');
    _debug_cmd(['/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host, $cmd], $timeout);

    return 1;
}

# List first LUN ID
sub _list_lu {
    my ($scfg, $timeout, $zvol) = @_;
    my $ids = _list_targetextent_ids($scfg, $timeout, $zvol);
    return $ids->[0] if @$ids;
    return;
}

# Query extent path
sub _list_extent {
    my ($scfg, $timeout, $zvol) = @_;
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    (my $name = $zvol) =~ s{^.*/}{};
    my $f = encode_json([[ 'path', '=', "zvol/$name" ]]);
    syslog('debug', "_list_extent filter: $f");
    my @cmd = ('/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        qq(midclt call iscsi.extent.query '$f'));
    my $out = _debug_cmd(\@cmd, $timeout)->{out};
    my $arr = decode_json($out||'[]');
    return $arr->[0]{path} if @$arr;
    return;
}

# Query NAA
sub _list_naa {
    my ($scfg, $timeout, $zvol) = @_;
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    (my $name = $zvol) =~ s{^.*/}{};
    my $f = encode_json([[ 'path', '=', "zvol/$name" ]]);
    syslog('debug', "_list_naa filter: $f");
    my @cmd = ('/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        qq(midclt call iscsi.extent.query '$f'));
    my $out = _debug_cmd(\@cmd, $timeout)->{out};
    my $arr = decode_json($out||'[]');
    return $arr->[0]{naa} if @$arr;
    return;
}

# Helper: query extent ID
sub _query_extent_id {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;

    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    # build JSON filter for full path
    my $filter = encode_json([[ 'path', '=', $zvol ]]);
    syslog('debug', "_query_extent_id filter: $filter");

    # run the SSH command
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.extent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);

    croak "TrueNAS: extent.query failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    # decode JSON response
    my $data = decode_json($res->{out} || '[]');

    # extract the ID
    my $eid;
    if (ref($data) eq 'ARRAY' && @$data) {
        $eid = $data->[0]{id};
    }
    elsif (ref($data) eq 'HASH') {
        $eid = $data->{id};
    }
    else {
        croak "TrueNAS: unexpected JSON from extent.query: $res->{out}";
    }

    syslog('debug', "_query_extent_id extracted extent ID: $eid");
    return $eid;
}

# Helper: query target ID
sub _query_target_id {
    my ($scfg, $timeout) = @_;
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    syslog('debug', "_query_target_id");

    # build and run the SSH command
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.target.query'
    );
    my $res = _debug_cmd(\@cmd, $timeout);

    croak "TrueNAS: target.query failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    # decode the JSON response
    my $data = decode_json($res->{out} || '[]');

    # extract the ID
    my $tid;
    if (ref($data) eq 'ARRAY' && @$data) {
        $tid = $data->[0]{id};
    }
    elsif (ref($data) eq 'HASH') {
        $tid = $data->{id};
    }
    else {
        croak "TrueNAS: unexpected JSON from target.query: $res->{out}";
    }

    syslog('debug', "_query_target_id extracted target ID: $tid");
    return $tid;
}


# Helper: list targetextent IDs
sub _list_targetextent_ids {
    my ($scfg, $timeout, $zvol) = @_;
    my $eid  = _query_extent_id($scfg, $timeout, $zvol);
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    my $f      = encode_json([[ 'extent', '=', $eid ]]);
    syslog('debug', "_list_targetextent_ids filter: $f");
    my @cmd = ('/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        qq(midclt call iscsi.targetextent.query '$f'));
    my $out = _debug_cmd(\@cmd, $timeout)->{out};
    my $arr = decode_json($out||'[]');
    return [ map { $_->{id} } @$arr ];
}

1;
