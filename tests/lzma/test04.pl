#!/usr/bin/perl
#
# Helper of test04.lua: runs lzma jobs with Perl's Compress::Raw::Lzma and IO::Compress::Xz /
# IO::Compress::Lzma / IO::Uncompress::UnXz / IO::Uncompress::UnLzma. Reads a job file (one
# job per line, fields separated by tabs), writes the result of each job into
# "<dir>/<id>.perl".
#
#   easy     id in preset extreme check     Compress::Raw::Lzma::EasyEncoder
#   stream   id in filter check             Compress::Raw::Lzma::StreamEncoder
#   alone    id in filter                   Compress::Raw::Lzma::AloneEncoder
#   rawenc   id in filter                   Compress::Raw::Lzma::RawEncoder
#            the input is fed with code() in pieces of chunk bytes (field "chunk" of the
#            encoders: always all at once here), then flush() (LZMA_FINISH)
#   decode   id in kind filter props chunk
#            kind: stream, alone, auto or raw (Compress::Raw::Lzma::StreamDecoder,
#            AloneDecoder, AutoDecoder, RawDecoder), filter for raw, props: a file with the
#            Properties of RawDecoder or "-"; the input is fed with code() in pieces of
#            chunk bytes (0: all at once, ConsumeInput); result: "<statuses> <rest>",
#            statuses: the status numbers of the calls, comma separated (until the first
#            status other than LZMA_OK), rest: the length of the input left after the last
#            call; the output goes into "<dir>/<id>.out"
#   ioxz     id in preset                   IO::Compress::Xz (Preset)
#   iolzma   id in                          IO::Compress::Lzma
#   unxz / unlzma id in                     IO::Uncompress::UnXz / UnLzma; the output goes
#            into "<dir>/<id>.out", the result is "ok" or "error"
#
# filter: "-" for none, else "lzma1" or "lzma2", optionally followed by ":" and the options
# of Lzma::Filter::Lzma1/Lzma2 (DictSize=n,Lc=n,Lp=n,Pb=n,Mode=n,Nice=n,Mf=n,Depth=n), or
# "lzma1p:<preset>" / "lzma2p:<preset>" for Lzma::Filter::Lzma1::Preset / Lzma2::Preset.
# Files are given relative to <dir>.

use strict;
use warnings;

use Compress::Raw::Lzma;
use IO::Compress::Xz qw(xz $XzError);
use IO::Compress::Lzma qw(lzma $LzmaError);
use IO::Uncompress::UnXz qw(unxz $UnXzError);
use IO::Uncompress::UnLzma qw(unlzma $UnLzmaError);

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

sub filter {
    my ($spec) = @_;
    return () if $spec eq '-';
    my ($type, $args) = split /:/, $spec, 2;
    if ($type eq 'lzma1p') { return (Lzma::Filter::Lzma1::Preset($args)); }
    if ($type eq 'lzma2p') { return (Lzma::Filter::Lzma2::Preset($args)); }
    my @opts = map { split /=/, $_, 2 } split /,/, (defined $args ? $args : '');
    return $type eq 'lzma1' ? (Lzma::Filter::Lzma1(@opts)) : (Lzma::Filter::Lzma2(@opts));
}

sub encode {
    my ($x, $status, $data) = @_;
    die "encoder: $status" unless $x;
    my $out = '';
    $status = $x->code($data, $out);
    die "code: $status" unless $status == LZMA_OK;
    my $rest = '';
    $status = $x->flush($rest);
    die "flush: $status" unless $status == LZMA_OK || $status == LZMA_STREAM_END;
    return $out . $rest;
}

open(my $jf, '<', "$dir/$jobs") or die "cannot open $dir/$jobs: $!";
while (my $line = <$jf>) {
    chomp $line;
    next if $line eq '';
    my ($op, $id, @a) = split /\t/, $line;
    my $out = '';
    if ($op eq 'easy') {
        my ($in, $preset, $extreme, $check) = @a;
        $out = encode(Compress::Raw::Lzma::EasyEncoder->new(Preset => $preset, Extreme => $extreme,
                                                            Check => $check), readFile($in));
    } elsif ($op eq 'stream') {
        my ($in, $f, $check) = @a;
        $out = encode(Compress::Raw::Lzma::StreamEncoder->new(Filter => [filter($f)], Check => $check),
                      readFile($in));
    } elsif ($op eq 'alone') {
        my ($in, $f) = @a;
        $out = encode(Compress::Raw::Lzma::AloneEncoder->new(Filter => filter($f)), readFile($in));
    } elsif ($op eq 'rawenc') {
        my ($in, $f) = @a;
        $out = encode(Compress::Raw::Lzma::RawEncoder->new(Filter => [filter($f)]), readFile($in));
    } elsif ($op eq 'decode') {
        my ($in, $kind, $f, $props, $chunk) = @a;
        my $data = readFile($in);
        my %opts = (AppendOutput => 1, ConsumeInput => 1);
        my ($x, $status);
        if ($kind eq 'stream') {
            ($x, $status) = Compress::Raw::Lzma::StreamDecoder->new(%opts);
        } elsif ($kind eq 'alone') {
            ($x, $status) = Compress::Raw::Lzma::AloneDecoder->new(%opts);
        } elsif ($kind eq 'auto') {
            ($x, $status) = Compress::Raw::Lzma::AutoDecoder->new(%opts);
        } else {
            my $p = readFile($props);
            $opts{Properties} = $p if defined $p;
            ($x, $status) = Compress::Raw::Lzma::RawDecoder->new(%opts, Filter => [filter($f)]);
        }
        die "decoder: $status" unless $x;
        my @statuses;
        my $result = '';
        my $rest = 0;
        my @pieces = $chunk > 0 ? unpack("(a$chunk)*", $data) : ($data);
        @pieces = ('') unless @pieces;
        for my $p (@pieces) {
            my $buf = $p;
            $status = $x->code($buf, $result);
            push @statuses, 0 + $status;
            $rest = length($buf);
            last if $status != LZMA_OK;
        }
        writeFile("$id.out", $result);
        $out = join(',', @statuses) . " $rest";
    } elsif ($op eq 'ioxz') {
        my ($in, $preset) = @a;
        my $data = readFile($in);
        xz(\$data => \$out, Preset => $preset) or die "xz: $XzError";
    } elsif ($op eq 'iolzma') {
        my ($in) = @a;
        my $data = readFile($in);
        lzma(\$data => \$out) or die "lzma: $LzmaError";
    } elsif ($op eq 'unxz' || $op eq 'unlzma') {
        my ($in) = @a;
        my $data = readFile($in);
        my $result;
        my $ok = $op eq 'unxz' ? unxz(\$data => \$result) : unlzma(\$data => \$result);
        writeFile("$id.out", $ok ? $result : '');
        $out = $ok ? "ok" : "error";
    } else {
        die "unknown job: $op";
    }
    writeFile("$id.perl", $out);
}
close($jf);
