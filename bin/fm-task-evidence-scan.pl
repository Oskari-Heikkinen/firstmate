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
# snapshot records one declared source's (or carried earlier copy's) metadata
# inventory before it is copied; recheck repeats every walk, refuses any change,
# and rehashes the regular files whose mtime or ctime is not older than their
# snapshot by the timestamp margin below, against the staged manifest. This is
# what lets the copy run outside teardown's project lock (the library header owns
# that contract). Citation parsing, object survival and installation remain in
# the library, under the lock. Perl and grep are existing runtime dependencies;
# Time::HiRes, Storable and Digest::SHA are Perl core modules. Unreadable
# records/directories retain the old grep/find skip policy, with one non-blocking
# WARNING per skipped path across prepare and verify calls for this scan; a
# snapshot records an unreadable path as such instead, so the copy's own refusal
# is unchanged.
use strict;
use warnings;
use Time::HiRes ();
use Storable qw(nstore retrieve);
use Digest::SHA ();

my ($mode, $dir, $scratch, @roots) = @ARGV;
sub refuse { die "REFUSED: evidence record scan: $_[0]; retry teardown\n"; }
sub refuse_copy { die "REFUSED: evidence copy check: $_[0]; nothing was changed; retry teardown\n"; }
defined($scratch) && defined($mode) && $mode =~ /\A(?:prepare|verify|snapshot|recheck)\z/
    or refuse('invalid invocation');
# Coarse filesystem clocks and 2 s FAT timestamps can give a later write the
# same recorded time as the snapshot's; such a file is rehashed under the lock.
my $racy_margin = 3;

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
# The first path whose presence or signature differs, or undef when none does.
sub changed {
    my ($a, $b) = @_;
    for my $path (sort keys %$a) {
        return $path unless exists($b->{$path}) && $a->{$path} eq $b->{$path};
    }
    for my $path (sort keys %$b) {
        return $path unless exists($a->{$path});
    }
    return undef;
}
sub same { return !defined(changed(@_)); }

if ($mode eq 'snapshot') {
    my ($index, $key) = @roots;
    defined($key) && $index =~ /\A[0-9]+\z/ or refuse_copy('invalid snapshot invocation');
    my $t0 = Time::HiRes::time() - $racy_margin;
    my ($entries) = inventory($dir, 0);
    eval { nstore({ root => $dir, key => $key, t0 => $t0, entries => $entries },
        "$scratch/snapshot.$index") } or refuse_copy("cannot save the snapshot of $dir");
    exit 0;
}

if ($mode eq 'recheck') {
    my ($count) = @roots;
    defined($count) && $count =~ /\A[0-9]+\z/ or refuse_copy('invalid recheck invocation');
    my %staged;
    my @racy;
    for my $index (0 .. $count - 1) {
        my $snap = eval { retrieve("$scratch/snapshot.$index") };
        $snap or refuse_copy("cannot read copy snapshot $index");
        my ($root, $key, $t0) = @$snap{qw(root key t0)};
        my ($entries, $times) = inventory($root, 0);
        my $path = changed($snap->{entries}, $entries);
        defined($path) and refuse_copy("$path changed while it was copied outside the project lock");
        for my $file (sort keys %$times) {
            push @racy, [$file, $key . substr($file, length($root))] if $times->{$file} >= $t0;
        }
    }
    exit 0 unless @racy;
    open(my $manifest, '<', "$dir/MANIFEST.sha256") or refuse_copy('cannot read the staged manifest');
    while (my $line = <$manifest>) {
        chomp($line);
        # sha256sum and shasum mark an escaped name with a leading backslash.
        $line =~ /\A\\?([0-9a-f]{64})  (.*)\z/s or refuse_copy('malformed staged manifest line');
        $staged{$2} = $1;
    }
    close($manifest) or refuse_copy("cannot read the staged manifest: $!");
    for my $item (@racy) {
        my ($file, $name) = @$item;
        # A file the copy did not manifest was never verified; nothing to compare.
        next unless exists($staged{$name});
        my $sha = Digest::SHA->new(256);
        my $hash = eval { $sha->addfile($file, 'b'); $sha->hexdigest };
        defined($hash) && $hash eq $staged{$name}
            or refuse_copy("$file changed while it was copied outside the project lock");
    }
    exit 0;
}

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
