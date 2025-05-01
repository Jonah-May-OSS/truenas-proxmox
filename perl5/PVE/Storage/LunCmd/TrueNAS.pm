package PVE::Storage::LunCmd::TrueNAS;

use strict;
use warnings;
use Carp qw(croak);
use JSON qw(decode_json);
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
    return _modify_lu($scfg,  $timeout, $params[0])  if $method eq 'modify_lu';
    if ($method eq 'modify_lu') {
        _delete_lu($scfg, $timeout, $params[0]);
        return _create_lu($scfg, $timeout, $params[0]);
    }
    return _list_lu($scfg, $timeout,    $params[0]) if $method eq 'list_lu';
    return _list_view($scfg, $timeout,   $params[0]) if $method eq 'list_view';
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

    # derive dataset path and unique name
    (my $disk_path = $zvol) =~ s{^/dev/}{};    # "/dev/zvol/SSD01/vm-109-disk-0" → "zvol/SSD01/vm-109-disk-0"
    (my $name      = $disk_path) =~ s{^zvol/}{}; # "zvol/SSD01/vm-109-disk-0" → "SSD01/vm-109-disk-0"

    # build and exec create extent command
    my $payload = "'{ \"name\": \"$name\", \"type\": \"DISK\", \"disk\": \"$disk_path\" }'";
    syslog('debug', "_create_lu payload: $payload");
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.extent.create', $payload
    );

    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: extent.create failed (exit=$res->{exitcode}): $res->{err}" if $res->{exitcode} != 0;

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
    my $map_payload = "'{ \"target\" : $tid, \"extent\" : $eid}'";
    syslog('debug', "_create_lu map payload: $map_payload");
    @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.targetextent.create', $map_payload
    );
    my $map_res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: targetextent.create failed (exit=$map_res->{exitcode}): $map_res->{err}" if $map_res->{exitcode} != 0;

    return $eid;
}

# No-op for when PVE wants to “modify” a zvol (e.g. after a resize)
# TrueNAS extents automatically reflect the underlying zvol size,
# so there’s nothing to do here.
sub _modify_lu {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;
    syslog('debug', "_modify_lu no action for extent $zvol");
    return undef;
}

sub _delete_lu {
    my ($scfg, $timeout, $param) = @_;
    croak "TrueNAS: missing identifier" unless defined $param;

    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    # determine mapping‐record ID and extent ID
    my ($map_id, $eid);
    if ($param =~ /^\d+$/) {
        # treat $param as the mapping‐record ID
        $map_id = $param;
        my $f = qq('[[ "id","=",$map_id ]]');
        my $res = _debug_cmd(
            ['/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
             'midclt','call','iscsi.targetextent.query',$f],
            $timeout
        );
        my $arr = decode_json($res->{out} || '[]');
        croak "TrueNAS: no mapping $map_id" unless @$arr;
        $eid = $arr->[0]{extent};
    }
    else {
        # treat $param as an extent ID/path
        $eid    = _query_extent_id($scfg, $timeout, $param);
        ($map_id) = @{ _list_targetextent_ids($scfg, $timeout, $param) };
    }

    # 1) delete the mapping
    syslog('debug', "_delete_lu unmap mapping: $map_id");
    _debug_cmd(
      ['/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
       'midclt','call','iscsi.targetextent.delete',$map_id,'true'],
      $timeout
    );

    # 2) delete the extent
    syslog('debug', "_delete_lu delete extent: $eid");
    _debug_cmd(
      ['/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
       'midclt','call','iscsi.extent.delete',$eid,'true'],
      $timeout
    );

    return 1;
}


# Return the mapping-record ID for the given extent (vol GUID or path)
sub _list_lu {
    my ($scfg, $timeout, $extent) = @_;
    croak "TrueNAS: missing extent identifier" unless defined $extent;

    # normalize to numeric extent ID
    my $eid = _query_extent_id($scfg, $timeout, $extent);

    # build and run the targetextent.query for this extent
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    my $filter = "'[[ \"extent\", \"=\", $eid ]]'";
    syslog('debug', "_list_lu filter: $filter");
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.targetextent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: targetextent.query failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    # parse JSON and return the first mapping-record ID
    my $arr = decode_json($res->{out} || '[]');
    return $arr->[0]{id} if ref($arr) eq 'ARRAY' && @$arr;
    return;
}

# Query extent path
sub _list_extent {
    my ($scfg, $timeout, $zvol) = @_;
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    # use full zvol path
    my $filter = "'[[ \"path\", \"=\", \"$zvol\" ]]'";
    syslog('debug', "_list_extent filter: $filter");
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.extent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: extent.query failed (exit=$res->{exitcode}): $res->{err}" if $res->{exitcode} != 0;

    my $arr = decode_json($res->{out} || '[]');
    return $arr->[0]{path} if (ref($arr) eq 'ARRAY' && @$arr);
    return;
}

# Given that mapping-record ID, return its LUN number
sub _list_view {
    my ($scfg, $timeout, $mapid) = @_;
    croak "TrueNAS: missing mapping ID" unless defined $mapid;

    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    my $filter = "'[[ \"id\", \"=\", $mapid ]]'";
    syslog('debug', "_list_view filter: $filter");
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.targetextent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: targetextent.query failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    my $arr = decode_json($res->{out} || '[]');
    croak "TrueNAS: no mapping found for ID $mapid"
        unless ref($arr) eq 'ARRAY' && @$arr;

    my $lun = $arr->[0]{lunid};
    croak "TrueNAS: invalid lunid for mapping $mapid"
        unless defined($lun) && $lun =~ /^\d+$/;

    return "$lun";
}

# Helper: query extent ID (accepts either numeric ID or full zvol path)
sub _query_extent_id {
    my ($scfg, $timeout, $val) = @_;
    croak "TrueNAS: missing extent identifier" unless defined $val;

    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    # build filter based on whether $val is numeric (id) or not (path)
    my $filter;
    if ($val =~ /^\d+$/) {
        $filter = "'[[ \"id\", \"=\", $val ]]'";
    } else {
        $filter = "'[[ \"path\", \"=\", \"$val\" ]]'";
    }
    syslog('debug', "_query_extent_id filter: $filter");

    # run the SSH command
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.extent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: extent.query failed (exit=$res->{exitcode}): $res->{err}"
        if $res->{exitcode} != 0;

    # parse JSON and extract id
    my $data = decode_json($res->{out} || '[]');
    my $eid;
    if      (ref($data) eq 'ARRAY' && @$data) { $eid = $data->[0]{id} }
    elsif   (ref($data) eq 'HASH')            { $eid = $data->{id} }
    else   { croak "TrueNAS: unexpected JSON from extent.query: $res->{out}" }

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
    my @cmd = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.target.query'
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: target.query failed (exit=$res->{exitcode}): $res->{err}" if $res->{exitcode} != 0;

    my $data = decode_json($res->{out} || '[]');
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

# Helper: return an ARRAYREF of mapping‐record IDs for a given extent
sub _list_targetextent_ids {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;

    # get the numeric extent ID
    my $eid = _query_extent_id($scfg, $timeout, $zvol);
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";

    # query the mappings
    my $filter = "'[[ \"extent\", \"=\", $eid ]]'";
    my @cmd    = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.targetextent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: targetextent.query failed (exit=$res->{exitcode})"
        if $res->{exitcode} != 0;

    my $arr = decode_json($res->{out} || '[]');
    return [ map { $_->{id} } @$arr ];
}

# Helper: return an ARRAYREF of the actual LUN numbers for a given extent
sub _list_lun_ids {
    my ($scfg, $timeout, $zvol) = @_;
    croak "TrueNAS: missing zvol" unless defined $zvol;

    # same query as above, but pull lunid
    my $eid = _query_extent_id($scfg, $timeout, $zvol);
    my $portal = $scfg->{portal};
    my $key    = "$ID_RSA_PATH/${portal}_id_rsa";
    my $host   = "root\@$portal";
    my $filter = "'[[ \"extent\", \"=\", $eid ]]'";
    my @cmd    = (
        '/usr/bin/ssh', @SSH_OPTS, '-i', $key, $host,
        'midclt', 'call', 'iscsi.targetextent.query', $filter
    );
    my $res = _debug_cmd(\@cmd, $timeout);
    croak "TrueNAS: targetextent.query failed (exit=$res->{exitcode})"
        if $res->{exitcode} != 0;

    my $arr = decode_json($res->{out} || '[]');
    return [ map { $_->{lunid} } @$arr ];
}

1;
