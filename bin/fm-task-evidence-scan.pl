#!/usr/bin/env perl
# Bulk text prefilter and copy-change detector for fm-task-evidence-lib.sh.
# Usage: perl fm-task-evidence-scan.pl prepare|verify <dir> <scratch>
# [<copy-root> <tmp-root>]; snapshot <path> <scratch> <index> <key>; recheck
# <staging> <scratch> <count>. prepare inventories records, runs grep in bounded
# argv batches (per-record retries only after grep errors), and saves validated
# filename-NUL/line-LF pairs in matches. GNU and BSD grep share --null framing.
# verify does one metadata-only walk, refusing additions, removals, replacement
# or edits since prepare. Evidence and staging trees are excluded in both walks.
# prepare and verify never inspect a disposable root.
# snapshot/recheck delegate to fm-task-evidence-stream.py, the disk-backed
# copy inventory and hash owner. The library header owns their safety contract.
# Citation parsing, object survival and installation remain in the library.
# Perl/grep serve record scanning; Python 3 with stdlib sqlite3 serves copy
# scanning. Time::HiRes and Storable are Perl core modules. Unreadable record
# paths retain the skip policy, with one WARNING per path across prepare/verify.
use strict;
use warnings;
use Time::HiRes ();
use Storable qw(nstore retrieve);
use FindBin ();

my ($mode, $dir, $scratch, @roots) = @ARGV;
# Keep the existing entry point for callers, but one disk-backed implementation
# owns copy snapshots and comparisons; never load whole evidence inventories.
if (defined($mode) && ($mode eq 'snapshot' || $mode eq 'recheck')) {
    exec('python3', "$FindBin::Bin/fm-task-evidence-stream.py", @ARGV)
        or die "REFUSED: cannot start bounded evidence helper: $!\n";
}
sub refuse { die "REFUSED: evidence record scan: $_[0]; retry teardown\n"; }
defined($scratch) && defined($mode) && $mode =~ /\A(?:prepare|verify|snapshot|recheck)\z/
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

# Records mode (prepare/verify) walks <dir> without the evidence trees and keeps
# the skip policy; a snapshot walks one copied path and keeps every member.
# Returns the signatures and, for regular files, the newer of mtime and ctime.
sub inventory {
    my ($root, $records) = @_;
    my (%entries, %times);
    return (\%entries, \%times) unless -e $root || -l $root;
    my @pending = ($root);
    while (@pending) {
        my $path = pop @pending;
        next if $records && ($path eq "$root/evidence" || $path =~ /^\Q$root\E\/\.evidence\.[^\/]*$/);
        my @s = Time::HiRes::lstat($path);
        if (!@s) {
            if ($records) { skip_path($path); } else { $entries{$path} = 'unreadable'; }
            next;
        }
        # Directory timestamps change when preservation installs its own tree.
        # Membership is compared via the complete inventory instead. Symlinks
        # are not followed (matching find -type f); retain their own identity.
        my $is_dir = ($s[2] & 0170000) == 0040000;
        $entries{$path} = join(':', @s[0,1,2,4,5,6], $is_dir ? () :
            ($s[3], $s[7], sprintf('%.9f', $s[9]), sprintf('%.9f', $s[10])));
        if ($records && $path eq "$root/evidence.list" && -l $path) {
            my @target = Time::HiRes::stat($path);
            $entries{$path} .= @target ? join(':', 'target', @target[0,1,2,3,4,5,6,7],
                map { sprintf('%.9f', $_) } @target[9,10]) : ':missing-target';
        }
        if (!$records && ($s[2] & 0170000) == 0120000) {
            my $text = readlink($path);
            $entries{$path} .= defined($text) ? ":link:$text" : ':unreadable-link';
        }
        $times{$path} = $s[9] > $s[10] ? $s[9] : $s[10] if ($s[2] & 0170000) == 0100000;
        if ($is_dir) {
            if (opendir(my $dh, $path)) {
                push @pending, map { "$path/$_" } grep { $_ ne '.' && $_ ne '..' } readdir($dh);
                closedir($dh);
            } elsif ($records) {
                skip_path($path);
            } else {
                $entries{$path} .= ':unlisted';
            }
        }
    }
    return (\%entries, \%times);
}
# The first record path whose presence or signature differs, or undef.
sub changed {
    my ($a, $b) = @_;
    for my $path (sort keys %$a) {
        next if exists($b->{$path}) && $a->{$path} eq $b->{$path};
        return $path;
    }
    for my $path (sort keys %$b) {
        return $path unless exists($a->{$path});
    }
    return undef;
}
sub same { return !defined(changed(@_)); }

if ($mode eq 'verify') {
    my $saved = eval { retrieve("$scratch/inventory") };
    $saved or refuse('cannot read record inventory');
    same($saved, (inventory($dir, 1))[0]) or refuse('durable records changed since the unlocked scan');
    exit 0;
}

my ($before) = inventory($dir, 1);
open(my $out, '>', "$scratch/matches") or refuse("cannot stage matches: $!");
binmode($out);
s{/$}{} for @roots; # Match the library's lexical root normalization.
my @patterns = map { ('-e', "$_/") } grep { length } @roots;
my @files = sort grep { -f $_ && !-l $_ } keys %$before;
# Stage each attempt separately: exit 2 may mean a fatal error that leaves
# later files unread, not just a per-file read error. Discard batch partial
# output and retry all members individually to preserve siblings' matches.
sub run_grep {
    my (@batch) = @_;
    my $pid = fork();
    defined($pid) or refuse("cannot start grep: $!");
    if (!$pid) {
        open(STDOUT, '>', "$scratch/grep-matches") or refuse("cannot stage grep matches: $!");
        open(STDERR, '>', "$scratch/grep-errors") or refuse("cannot stage grep errors: $!");
        exec('grep', '-IHF', '--null', @patterns, '--', @batch) or refuse("cannot start grep: $!");
    }
    waitpid($pid, 0) == $pid or refuse('cannot wait for grep');
    my $status = $?;
    $status == 0 || $status == 256 || $status == 512 or refuse('grep failed');
    return $status;
}

sub append_matches {
    my (@batch) = @_;
    my %member = map { $_ => 1 } @batch;
    open(my $matches, '<', "$scratch/grep-matches") or refuse('cannot read grep matches');
    binmode($matches);
    while (1) {
        my $record = do { local $/ = "\0"; <$matches> };
        last unless defined($record);
        $record =~ s/\0\z// && exists($member{$record})
            or refuse('malformed grep record framing');
        my $line = <$matches>;
        defined($line) && $line =~ /\n\z/ && index($line, "\0") < 0
            or refuse('malformed grep line framing');
        print {$out} $record, "\0", $line or refuse("cannot write matches: $!");
    }
    eof($matches) or refuse("cannot read grep matches: $!");
    close($matches) or refuse("cannot close grep matches: $!");
}

# Stay below ARG_MAX even with long names; -I preserves the previous grep
# binary-file policy. Successful batches read every record once for both roots.
while (@files && @patterns) {
    my @batch;
    my $bytes = 0;
    while (@files && @batch < 256 && $bytes + length($files[0]) < 32768) {
        $bytes += length($files[0]) + 1;
        push @batch, shift @files;
    }
    @batch or refuse('record filename exceeds batch bound');
    if (run_grep(@batch) == 512) {
        for my $record (@batch) {
            if (run_grep($record) == 512) {
                open(my $errors, '<', "$scratch/grep-errors") or refuse('cannot read grep errors');
                my $text = do { local $/; <$errors> };
                close($errors);
                # Only a named per-file read error retains the agreed skip
                # policy. A fatal error on a single record cannot prove absence.
                # Recognize the entire diagnostic, not a filename substring:
                # a named read error followed by a fatal error still refuses.
                $text =~ /\A[^\n]*grep: \Q$record\E: [^\n]*\n\z/
                    or refuse("grep could not scan record $record; split the record, or declare its citations and remove the record before retrying");
                # The old per-record scan retained matches read before a named
                # read error. Validate them before keeping that skip policy.
                append_matches($record);
                skip_path($record);
                next;
            }
            append_matches($record);
        }
    } else {
        append_matches(@batch);
    }
}
close($out) or refuse("cannot close matches: $!");
same($before, (inventory($dir, 1))[0]) or refuse('durable records changed during the unlocked scan');
eval { nstore($before, "$scratch/inventory") }
    or refuse('cannot save record inventory');
