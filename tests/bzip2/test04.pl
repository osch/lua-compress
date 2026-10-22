#!/usr/bin/perl
#
# Helper of test04.lua: runs bzip2 jobs with Perl's Compress::Raw::Bzip2 and
# IO::Compress::Bzip2 / IO::Uncompress::Bunzip2. Reads a job file (one job per line, fields
# separated by tabs), writes the result of each job into "<dir>/<id>.perl".
#
#   deflate  id in blockSize workFactor chunk flush
#            Compress::Raw::Bzip2->new(1, blockSize, workFactor): the input is fed with
#            bzdeflate() in pieces of chunk bytes (0: all at once), after each piece bzflush()
#            if flush is 1, then bzclose()
#   iobzip2  id in blockSize                IO::Compress::Bzip2 (BlockSize100K, "-": default)
#   decode   id in small chunk
#            Compress::Raw::Bunzip2->new(1, 1, small): the input is fed with bzinflate() in
#            pieces of chunk bytes (0: all at once, ConsumeInput); result: "<statuses> <rest>",
#            statuses: the status numbers of the calls, comma separated (until the first
#            status other than BZ_OK), rest: the length of the input left after the last
#            call; the output goes into "<dir>/<id>.out"
#   bunzip2  id in multistream              IO::Uncompress::Bunzip2 (MultiStream 0 or 1); the
#            output goes into "<dir>/<id>.out", the result is "ok" or "error"
#
# Files are given relative to <dir>.

use strict;
use warnings;

use Compress::Raw::Bzip2;
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);

my ($dir, $jobs) = @ARGV;

sub readFile {
    my ($name) = @_;
    open(my $f, '<:raw', "$dir/$name") or die "cannot open $dir/$name: $!";
    local $/;
    my $data = <$f>;
    close($f);
    return defined $data ? $data : '';
}

sub writeFile {
    my ($name, $data) = @_;
    open(my $f, '>:raw', "$dir/$name") or die "cannot write $dir/$name: $!";
    print $f $data;
    close($f);
}

sub pieces {
    my ($data, $chunk) = @_;
    my @p = $chunk > 0 ? unpack("(a$chunk)*", $data) : ($data);
    @p = ('') unless @p;
    return @p;
}

open(my $jf, '<', "$dir/$jobs") or die "cannot open $dir/$jobs: $!";
while (my $line = <$jf>) {
    chomp $line;
    next if $line eq '';
    my ($op, $id, @a) = split /\t/, $line;
    my $out = '';
    if ($op eq 'deflate') {
        my ($in, $bs, $wf, $chunk, $flush) = @a;
        my ($x, $status) = Compress::Raw::Bzip2->new(1, $bs, $wf);
        die "Compress::Raw::Bzip2: $status" unless $x;
        for my $p (pieces(readFile($in), $chunk)) {
            $status = $x->bzdeflate($p, $out);
            die "bzdeflate: $status" unless $status == BZ_RUN_OK || ($p eq "" && $status == BZ_OK);
            if ($flush) {
                $status = $x->bzflush($out);
                die "bzflush: $status" unless $status == BZ_RUN_OK;
            }
        }
        $status = $x->bzclose($out);
        die "bzclose: $status" unless $status == BZ_STREAM_END;
    } elsif ($op eq 'iobzip2') {
        my ($in, $bs) = @a;
        my $data = readFile($in);
        my @opts = $bs eq '-' ? () : (BlockSize100K => $bs);
        bzip2(\$data => \$out, @opts) or die "bzip2: $Bzip2Error";
    } elsif ($op eq 'decode') {
        my ($in, $small, $chunk) = @a;
        my ($x, $status) = Compress::Raw::Bunzip2->new(1, 1, $small);
        die "Compress::Raw::Bunzip2: $status" unless $x;
        my @statuses;
        my $result = '';
        my $rest = 0;
        for my $p (pieces(readFile($in), $chunk)) {
            my $buf = $p;
            $status = $x->bzinflate($buf, $result);
            push @statuses, 0 + $status;
            $rest = length($buf);
            last if $status != BZ_OK;
        }
        writeFile("$id.out", $result);
        $out = join(',', @statuses) . " $rest";
    } elsif ($op eq 'bunzip2') {
        my ($in, $multi) = @a;
        my $data = readFile($in);
        my $result;
        my $ok = bunzip2(\$data => \$result, MultiStream => $multi);
        writeFile("$id.out", $ok ? $result : '');
        $out = $ok ? "ok" : "error";
    } else {
        die "unknown job: $op";
    }
    writeFile("$id.perl", $out);
}
close($jf);
