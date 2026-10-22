#!/usr/bin/perl
#
# Helper of test04.lua: runs zlib jobs with Perl's Compress::Zlib, Compress::Raw::Zlib
# and IO::Compress / IO::Uncompress. Reads a job file (one job per line, fields
# separated by tabs), writes the result of each job into "<dir>/<id>.perl".
#
#   deflate  id in level method windowBits memLevel strategy dict chunk flush
#            Compress::Raw::Zlib::Deflate with these parameters, the input fed with
#            deflate() in pieces of chunk bytes (0: all at once), after each piece a
#            flush with flush ("none", "sync", "full"), at the end flush(Z_FINISH)
#   compress id in level              Compress::Zlib::compress
#   iogzip   id in level strategy os time name comment extra text hcrc
#            IO::Compress::Gzip with OS_Code => os, Time => time, and the header
#            fields Name, Comment, ExtraField (files, "-" for none), TextFlag, HeaderCRC
#            (0 or 1)
#   iodeflate id in level strategy    IO::Compress::Deflate
#   iorawdeflate id in level strategy IO::Compress::RawDeflate
#   inflate  id in windowBits dict chunk
#            Compress::Raw::Zlib::Inflate, the input fed in pieces of chunk bytes (0:
#            all at once, ConsumeInput); result: "<statuses> <rest> <len> <crc>",
#            statuses: the status numbers of the calls, comma separated, rest: the
#            length of the input left after the last call, len and crc: length and
#            crc32 of the output
#   uncompress id in                  Compress::Zlib::uncompress
#   gunzip / inflateio / rawinflate id in
#            IO::Uncompress::Gunzip / Inflate / RawInflate; result: "ok <len> <crc>"
#            or "error"
#   gunziphdr id in
#            IO::Uncompress::Gunzip, with its header info; result: "ok <len> <crc>
#            <os> <time> <text> <hcrc> <name> <comment> <extra>" (name, comment and
#            extra in hex, "-" if absent) or "error"
#
# Files are given relative to <dir>; "-" for no dictionary.

use strict;
use warnings;

use Compress::Zlib;
use Compress::Raw::Zlib;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Deflate qw(deflate $DeflateError);
use IO::Compress::RawDeflate qw(rawdeflate $RawDeflateError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Uncompress::Inflate qw(inflate $InflateError);
use IO::Uncompress::RawInflate qw(rawinflate $RawInflateError);

my ($dir, $jobs) = @ARGV;

sub readFile {
    my ($name) = @_;
    return undef if $name eq '-';
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

my %FLUSH = (none => undef, sync => Z_SYNC_FLUSH, full => Z_FULL_FLUSH);

open(my $jf, '<', "$dir/$jobs") or die "cannot open $dir/$jobs: $!";
while (my $line = <$jf>) {
    chomp $line;
    next if $line eq '';
    my ($op, $id, @a) = split /\t/, $line;
    my $out = '';
    if ($op eq 'deflate') {
        my ($in, $level, $method, $wbits, $memLevel, $strategy, $dict, $chunk, $flush) = @a;
        my $data = readFile($in);
        my %opts = (-Level => $level, -Method => $method, -WindowBits => $wbits,
                    -MemLevel => $memLevel, -Strategy => $strategy, -AppendOutput => 1);
        my $d = readFile($dict);
        $opts{-Dictionary} = $d if defined $d;
        my ($x, $status) = Compress::Raw::Zlib::Deflate->new(%opts);
        die "deflateInit: $status" unless $x;
        my @pieces = $chunk > 0 ? unpack("(a$chunk)*", $data) : ($data);
        for my $p (@pieces) {
            $status = $x->deflate($p, $out);
            die "deflate: $status" unless $status == Z_OK;
            if (defined $FLUSH{$flush}) {
                $status = $x->flush($out, $FLUSH{$flush});
                die "flush: $status" unless $status == Z_OK;
            }
        }
        $status = $x->flush($out);
        die "flush: $status" unless $status == Z_OK;
    } elsif ($op eq 'compress') {
        my ($in, $level) = @a;
        $out = Compress::Zlib::compress(readFile($in), $level);
        die "compress failed" unless defined $out;
    } elsif ($op eq 'iogzip') {
        my ($in, $level, $strategy, $os, $time, $name, $comment, $extra, $text, $hcrc) = @a;
        my $data = readFile($in);
        my %opts = (Level => $level, Strategy => $strategy, OS_Code => $os, Time => $time,
                    TextFlag => $text, HeaderCRC => $hcrc);
        $opts{Name}       = readFile($name)    if $name    ne '-';
        $opts{Comment}    = readFile($comment) if $comment ne '-';
        $opts{ExtraField} = readFile($extra)   if $extra   ne '-';
        gzip(\$data => \$out, %opts)
            or die "gzip: $GzipError";
    } elsif ($op eq 'iodeflate') {
        my ($in, $level, $strategy) = @a;
        my $data = readFile($in);
        deflate(\$data => \$out, Level => $level, Strategy => $strategy)
            or die "deflate: $DeflateError";
    } elsif ($op eq 'iorawdeflate') {
        my ($in, $level, $strategy) = @a;
        my $data = readFile($in);
        rawdeflate(\$data => \$out, Level => $level, Strategy => $strategy)
            or die "rawdeflate: $RawDeflateError";
    } elsif ($op eq 'inflate') {
        my ($in, $wbits, $dict, $chunk) = @a;
        my $data = readFile($in);
        my %opts = (-WindowBits => $wbits, -AppendOutput => 1, -ConsumeInput => 1);
        my $d = readFile($dict);
        $opts{-Dictionary} = $d if defined $d;
        my ($x, $status) = Compress::Raw::Zlib::Inflate->new(%opts);
        die "inflateInit: $status" unless $x;
        my @statuses;
        my $result = '';
        my $rest = 0;
        my @pieces = $chunk > 0 ? unpack("(a$chunk)*", $data) : ($data);
        @pieces = ('') unless @pieces;
        for my $p (@pieces) {
            my $buf = $p;
            $status = $x->inflate($buf, $result);
            push @statuses, 0 + $status;
            $rest = length($buf);
            last if $status != Z_OK;
        }
        $out = join(',', @statuses) . " $rest " . length($result) . " " . crc32($result);
    } elsif ($op eq 'uncompress') {
        my ($in) = @a;
        $out = Compress::Zlib::uncompress(readFile($in));
        $out = defined $out ? "ok " . length($out) . " " . crc32($out) : "error";
    } elsif ($op eq 'gunzip' || $op eq 'inflateio' || $op eq 'rawinflate') {
        my ($in) = @a;
        my $data = readFile($in);
        my $result;
        my $ok = $op eq 'gunzip'    ? gunzip(\$data => \$result)
               : $op eq 'inflateio' ? inflate(\$data => \$result)
               :                      rawinflate(\$data => \$result);
        $out = $ok ? "ok " . length($result) . " " . crc32($result) : "error";
    } elsif ($op eq 'gunziphdr') {
        my ($in) = @a;
        my $data = readFile($in);
        my $z = IO::Uncompress::Gunzip->new(\$data, Transparent => 0);
        if (!$z) {
            $out = "error";
        } else {
            my $result = '';
            my $st;
            1 while ($st = $z->read($result, 65536, length($result))) > 0;
            my $h = $z->getHeaderInfo();
            my $hex = sub { defined $_[0] ? unpack("H*", $_[0]) : '-' };
            $out = $st < 0 || !$h ? "error"
                 : join(' ', "ok", length($result), crc32($result), $h->{OsID}, $h->{Time},
                        $h->{TextFlag}, $h->{HeaderCRCFlag}, $hex->($h->{Name}),
                        $hex->($h->{Comment}), $hex->($h->{ExtraFieldRaw}));
        }
    } else {
        die "unknown job: $op";
    }
    writeFile("$id.perl", $out);
}
close($jf);
