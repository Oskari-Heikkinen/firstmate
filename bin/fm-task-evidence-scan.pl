#!/usr/bin/env perl
# Bulk text prefilter for fm-task-evidence-lib.sh; never inspects a disposable
# root. Usage: perl fm-task-evidence-scan.pl prepare|verify <dir> <scratch>
# [<copy-root> <tmp-root>]. prepare inventories records, runs grep in bounded
# argv batches (not per record), and saves filename-NUL/line pairs in matches.
# verify does one metadata-only walk, refusing additions, removals, replacement
# or edits since prepare. Evidence and staging trees are excluded in both walks.
# Citation parsing, object survival, copy verification and manifests remain in
# the library, under teardown's project lock. Perl and grep are existing runtime
# dependencies; Time::HiRes and Storable are Perl core modules. Unreadable
# records/directories retain the old grep/find skip policy, with one non-blocking
# WARNING per skipped path across prepare and verify calls for this scan.
use strict;
use warnings;
use Time::HiRes ();
use Storable qw(nstore retrieve);

my ($mode, $dir, $scratch, @roots) = @ARGV;
sub refuse { die "REFUSED: evidence record scan: $_[0]; retry teardown\n"; }
defined($scratch) && ($mode eq 'prepare' || $mode eq 'verify')
    or refuse('invalid invocation');

my $skipped_file = "$scratch/skipped";
my $skipped = -e $skipped_file ? eval { retrieve($skipped_file) } : {};
$skipped or refuse('cannot read skipped-path inventory');
sub skip_path {
    my ($path) = @_;
    return if $skipped->{$path}++;
    warn "WARNING: skipping unreadable evidence record or directory $path\n";
    eval { nstore($skipped, $skipped_file) }
        or refuse('cannot save skipped-path inventory');
}

sub inventory {
    my %entries;
    return \%entries unless -e $dir || -l $dir;
    my @pending = ($dir);
    while (@pending) {
        my $path = pop @pending;
        next if $path eq "$dir/evidence" || $path =~ /^\Q$dir\E\/\.evidence\.[^\/]*$/;
        my @s = Time::HiRes::lstat($path);
        if (!@s) { skip_path($path); next; }
        # Directory timestamps change when preservation installs its own tree.
        # Membership is compared via the complete inventory instead. Symlinks
        # are not followed (matching find -type f); retain their own identity.
        my $is_dir = ($s[2] & 0170000) == 0040000;
        $entries{$path} = join(':', @s[0,1,2,4,5,6], $is_dir ? () :
            ($s[3], $s[7], sprintf('%.9f', $s[9]), sprintf('%.9f', $s[10])));
        if ($path eq "$dir/evidence.list" && -l $path) {
            my @target = Time::HiRes::stat($path);
            $entries{$path} .= @target ? join(':', 'target', @target[0,1,2,3,4,5,6,7],
                map { sprintf('%.9f', $_) } @target[9,10]) : ':missing-target';
        }
        if ($is_dir) {
            if (opendir(my $dh, $path)) {
                push @pending, map { "$path/$_" } grep { $_ ne '.' && $_ ne '..' } readdir($dh);
                closedir($dh);
            } else {
                skip_path($path);
            }
        }
    }
    return \%entries;
}
sub same {
    my ($a, $b) = @_;
    keys(%$a) == keys(%$b) or return 0;
    for my $path (keys %$a) {
        return 0 unless exists($b->{$path}) && $a->{$path} eq $b->{$path};
    }
    return 1;
}

if ($mode eq 'verify') {
    my $saved = eval { retrieve("$scratch/inventory") };
    $saved or refuse('cannot read record inventory');
    same($saved, inventory()) or refuse('durable records changed since the unlocked scan');
    exit 0;
}

my $before = inventory();
open(my $out, '>', "$scratch/matches") or refuse("cannot stage matches: $!");
binmode($out);
s{/$}{} for @roots; # Match the library's lexical root normalization.
my @patterns = map { ('-e', "$_/") } grep { length } @roots;
my @files = sort grep { -f $_ && !-l $_ } keys %$before;
# Stay below ARG_MAX even with long names; one process per bounded batch,
# never one per record. -I preserves the previous grep binary-file policy.
while (@files && @patterns) {
    my @batch;
    my $bytes = 0;
    while (@files && @batch < 256 && $bytes + length($files[0]) < 32768) {
        $bytes += length($files[0]) + 1;
        push @batch, shift @files;
    }
    @batch or refuse('record filename exceeds batch bound');
    my $pid = open(my $grep, '-|');
    defined($pid) or refuse("cannot start grep: $!");
    if (!$pid) {
        open(STDERR, '>', "$scratch/grep-errors") or refuse("cannot stage grep errors: $!");
        exec('grep', '-IHZF', @patterns, '--', @batch) or refuse("cannot start grep: $!");
    }
    binmode($grep);
    my $buffer;
    while (read($grep, $buffer, 65536)) {
        print {$out} $buffer or refuse("cannot write matches: $!");
    }
    eof($grep) or refuse("cannot read grep: $!");
    close($grep);
    if ($? == 512) {
        # Retain other records' matches when grep cannot read one member, as
        # the old per-record loop did. Match known paths, not localized prose.
        open(my $errors, '<', "$scratch/grep-errors") or refuse('cannot read grep errors');
        my $text = do { local $/; <$errors> };
        close($errors);
        my @unreadable = grep { index($text, "$_:") >= 0 } @batch;
        if (@unreadable) {
            skip_path($_) for @unreadable;
        } else {
            # An unusual grep error without a recognizable filename still
            # must not restore the old silent skip: name the affected batch.
            warn 'WARNING: evidence grep could not complete for records: ' . join(', ', @batch) . "\n";
        }
    } elsif ($? != 0 && $? != 256) {
        refuse('grep failed');
    }
}
close($out) or refuse("cannot close matches: $!");
same($before, inventory()) or refuse('durable records changed during the unlocked scan');
eval { nstore($before, "$scratch/inventory") }
    or refuse('cannot save record inventory');
