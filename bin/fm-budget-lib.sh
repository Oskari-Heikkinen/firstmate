#!/usr/bin/env bash
# fm-budget-lib.sh - standing budgets: the record format, the spend ledger,
# the shadow log, and the inside-or-over check.
#
# bin/fm-budget.sh owns every command; bin/fm-decision-packet-lib.sh asks this
# file whether a packet's authority is a standing budget that may carry a
# default. This file owns only the formats and the arithmetic, so the rules
# below have one home. docs/budgets.md describes them for readers.
#
# A STANDING BUDGET is one file, <config>/budgets/<id>.budget, approved once by
# a quote. One `key: value` per line; blank lines and `#` lines are ignored:
#   schema: fm-budget.v1                    exactly once
#   id: <id>                                exactly once; equals the file name
#   covers: campaign <slug> | kind <slug>   exactly once
#   owner: <slug>                           exactly once; the home owning the policy
#   core-hours: <N>[.<NNN>] | none          exactly once; the core-hour cap
#   disk-bytes: <N> | none                  exactly once; the disk cap in bytes
#   end-date: YYYY-MM-DD                    exactly once; the last day inside budget
#   over-budget-default: approve | refuse   exactly once; the gate row's default
#   deadline-offset: <N>h | <N>d            exactly once; the gate row's deadline
#   shadow: on | off                        optional; on when absent (shadow first)
#   approved-at: <UTC YYYY-MM-DDTHH:MM:SSZ> exactly once; when the quote was given
#   quote: <text>                           at least once; verbatim, in order
# <id> is [A-Za-z0-9_-]+ (no dot, so the packet authority `budget.<id>` is
# unambiguous). A record with no quote, or with no approved-at, is not a
# standing budget and is refused, as is any unknown or repeated key.
#
# The SPEND LEDGER is <data>/budgets/<id>.spend.jsonl, one fm-budget-spend.v1
# object per line: schema, budget, request, core_hours, disk_bytes, at. A check
# reads either the spend files it is given or this ledger, never another
# home's state; records for another budget are skipped, a request id counts
# once (its first record), and an unreadable record fails the check closed.
#
# The SHADOW LOG is <data>/budgets/<id>.shadow.jsonl: one fm-budget-shadow.v1
# object per `check` or `open-gate` run against a budget with shadow on,
# recording what would have happened. It is append-only.

FM_BUDGET_SCHEMA=fm-budget.v1
FM_BUDGET_SPEND_SCHEMA=fm-budget-spend.v1
FM_BUDGET_SHADOW_SCHEMA=fm-budget-shadow.v1
FM_BUDGET_CHECK_SCHEMA=fm-budget-check.v1
FM_BUDGET_AUTHORITY_PREFIX=budget.

fm_budget_path() {  # <config-dir> <id>
  printf '%s/budgets/%s.budget\n' "$1" "$2"
}

fm_budget_ledger_path() {  # <data-dir> <id>
  printf '%s/budgets/%s.spend.jsonl\n' "$1" "$2"
}

fm_budget_shadow_path() {  # <data-dir> <id>
  printf '%s/budgets/%s.shadow.jsonl\n' "$1" "$2"
}

fm_budget_id_valid() {  # <id>
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# fm_budget_authority_id <authority>: the budget id a `budget.<id>` authority
# names, or nonzero when the authority is not a budget authority.
fm_budget_authority_id() {
  case "$1" in
    "$FM_BUDGET_AUTHORITY_PREFIX"*) : ;;
    *) return 1 ;;
  esac
  fm_budget_id_valid "${1#"$FM_BUDGET_AUTHORITY_PREFIX"}" || return 1
  printf '%s\n' "${1#"$FM_BUDGET_AUTHORITY_PREFIX"}"
}

# fm_budget_load <config-dir> <id>: validate the budget record and print its
# normalized lines (shadow always present). On refusal returns 1 with the
# reason on stderr.
fm_budget_load() {
  local config=$1 id=$2 path out rc=0
  fm_budget_id_valid "$id" || { printf 'budget id must match [A-Za-z0-9_-]+: %s\n' "$id" >&2; return 1; }
  path=$(fm_budget_path "$config" "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || { printf 'no standing budget %s at %s\n' "$id" "$path" >&2; return 1; }
  out=$(perl -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($path, $id, $schema) = @ARGV;
    sub refuse { print STDERR "budget $id refused: $_[0]\n"; exit 1; }
    open(my $f, "<", $path) or refuse("cannot be read: $path");
    local $/; my $text = <$f>; close $f;
    refuse("record exceeds 65536 bytes") if length($text) > 65536;
    my %single = map { $_ => 1 } qw(schema id covers owner core-hours disk-bytes end-date
      over-budget-default deadline-offset shadow approved-at);
    my (%one, @quote);
    my $n = 0;
    for my $line (split /\n/, $text) {
      ++$n;
      $line =~ s/\r$//;
      next if $line =~ /^\s*(#|$)/;
      if ($line =~ /^quote:[ ]?(.*)$/) {
        my $q = $1;
        refuse("line $n holds a control character") if $q =~ /[\x00-\x08\x0a-\x1f\x7f]/;
        refuse("line $n has an empty quote") unless $q =~ /\S/;
        push @quote, $q;
        next;
      }
      $line =~ /^([a-z-]+):[ \t]*(.*?)[ \t]*$/ or refuse("line $n is not key: value");
      my ($key, $value) = ($1, $2);
      refuse("unknown key: $key") unless $single{$key};
      refuse("key $key may appear only once") if exists $one{$key};
      refuse("line $n has an empty $key") if $value eq "";
      refuse("line $n holds a control character") if $value =~ /[\x00-\x1f\x7f]/;
      $one{$key} = $value;
    }
    refuse("it records no quote, so it is not a standing budget") unless @quote;
    $one{shadow} //= "on";
    for my $key (sort keys %single) {
      refuse("it needs $key") unless exists $one{$key};
    }
    refuse("schema must be $schema: $one{schema}") unless $one{schema} eq $schema;
    refuse("id $one{id} does not match the file name $id") unless $one{id} eq $id;
    $one{covers} =~ /^(campaign|kind) [A-Za-z0-9._-]+$/
      or refuse("covers must be campaign <slug> or kind <slug>: $one{covers}");
    $one{owner} =~ /^[A-Za-z0-9._-]+$/ or refuse("owner must be a slug: $one{owner}");
    $one{"core-hours"} =~ /^(none|\d{1,12}(\.\d{1,3})?)$/
      or refuse("core-hours must be a number with at most three decimals, or none: " . $one{"core-hours"});
    $one{"disk-bytes"} =~ /^(none|\d{1,16})$/
      or refuse("disk-bytes must be a whole number of bytes, or none: " . $one{"disk-bytes"});
    $one{"end-date"} =~ /^(\d{4})-(\d\d)-(\d\d)$/ && eval { timegm(0, 0, 0, $3, $2 - 1, $1); 1 }
      or refuse("end-date must be a YYYY-MM-DD date: " . $one{"end-date"});
    $one{"over-budget-default"} =~ /^(approve|refuse)$/
      or refuse("over-budget-default must be approve or refuse: " . $one{"over-budget-default"});
    $one{"deadline-offset"} =~ /^([1-9]\d{0,3}h|[1-9]\d{0,2}d)$/
      or refuse("deadline-offset must be <N>h or <N>d: " . $one{"deadline-offset"});
    $one{shadow} =~ /^(on|off)$/ or refuse("shadow must be on or off: $one{shadow}");
    $one{"approved-at"} =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/
      && eval { timegm($6, $5, $4, $3, $2 - 1, $1); 1 }
      or refuse("approved-at must be a UTC YYYY-MM-DDTHH:MM:SSZ time: " . $one{"approved-at"});
    for my $key (qw(schema id covers owner core-hours disk-bytes end-date over-budget-default
                    deadline-offset shadow approved-at)) {
      print "$key: $one{$key}\n";
    }
    print "quote: $_\n" for @quote;
  ' -- "$path" "$id" "$FM_BUDGET_SCHEMA" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# fm_budget_shadow_append <data-dir> <at> <budget-id> <command> <request>
#   <verdict> <exceeded|none> <would> [<task> <default> <deadline-offset>]
# Appends one fm-budget-shadow.v1 record: what <command> would have done.
fm_budget_shadow_append() {
  local log line
  log=$(fm_budget_shadow_path "$1" "$3")
  (umask 077; mkdir -p "${log%/*}") || return 1
  line=$(perl -MJSON::PP -e '
    my ($schema, $at, $budget, $command, $request, $verdict, $exceeded, $would, $task, $default, $offset) = @ARGV;
    my %r = (schema => $schema, at => $at, budget => $budget, command => $command,
      request => $request, verdict => $verdict, would => $would,
      exceeded => [grep { length } split /,/, ($exceeded eq "none" ? "" : $exceeded)]);
    $r{task} = $task if length($task // "");
    $r{default} = $default if length($default // "");
    $r{deadline_offset} = $offset if length($offset // "");
    print JSON::PP->new->canonical->encode(\%r);
  ' -- "$FM_BUDGET_SHADOW_SCHEMA" "${@:2}") || return 1
  printf '%s\n' "$line" >> "$log"
}

# fm_budget_field <normalized-record> <key>: the first value of <key>.
fm_budget_field() {
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

# fm_budget_check <normalized-record> <request-id> <core-hours> <disk-bytes>
#   <date> <now> <json:0|1> <spend-file>...
# Prints the verdict as text, or as one fm-budget-check.v1 JSON object. Returns
# 1 with the reason on stderr when the request or a spend record is malformed.
fm_budget_check() {
  local record=$1 out rc=0
  shift
  out=$(printf '%s\n' "$record" | perl -MJSON::PP -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($check_schema, $spend_schema, $request, $ch, $disk, $date, $now, $json, @spend) = @ARGV;
    sub refuse { print STDERR "$_[0]\n"; exit 1; }
    my %b;
    while (my $line = <STDIN>) { chomp $line; $b{$1} = $2 if $line =~ /^([a-z-]+): (.*)$/ && !exists $b{$1}; }
    sub milli {  # a non-negative decimal with at most three places, in thousandths
      my ($v, $label) = @_;
      $v =~ /^(\d{1,12})(?:\.(\d{1,3}))?$/ or refuse("$label must be a non-negative number with at most three decimals: $v");
      return $1 * 1000 + (defined $2 ? substr($2 . "00", 0, 3) : 0);
    }
    sub bytes {
      my ($v, $label) = @_;
      $v =~ /^\d{1,16}$/ or refuse("$label must be a whole number of bytes: $v");
      return $v + 0;
    }
    sub day {
      my ($v, $label) = @_;
      $v =~ /^(\d{4})-(\d\d)-(\d\d)$/ or refuse("$label must be a YYYY-MM-DD date: $v");
      my $e = eval { timegm(0, 0, 0, $3, $2 - 1, $1) };
      refuse("$label is not a valid date: $v") unless defined $e;
      return int($e / 86400);
    }
    my $req_ch = milli($ch, "--core-hours");
    my $req_disk = bytes($disk, "--disk-bytes");
    my $req_day = day($date, "--date");
    my $codec = JSON::PP->new;
    my ($spent_ch, $spent_disk, $records, %seen) = (0, 0, 0);
    for my $file (@spend) {
      open(my $f, "<", $file) or refuse("spend file cannot be read: $file");
      my $n = 0;
      while (my $line = <$f>) {
        ++$n;
        next unless $line =~ /\S/;
        my $r = eval { $codec->decode($line) };
        refuse("spend record $file:$n is not JSON") unless ref $r eq "HASH";
        refuse("spend record $file:$n is not $spend_schema") unless ($r->{schema} // "") eq $spend_schema;
        next unless ($r->{budget} // "") eq $b{id};
        my $rid = $r->{request} // "";
        refuse("spend record $file:$n has no request id") unless $rid =~ /^[A-Za-z0-9._:-]+$/;
        next if $seen{$rid}++;
        $spent_ch += milli($r->{core_hours} // "", "spend record $file:$n core_hours");
        $spent_disk += bytes($r->{disk_bytes} // "", "spend record $file:$n disk_bytes");
        ++$records;
      }
      close $f;
    }
    my $fmt = sub { my $m = shift; my $s = $m < 0 ? "-" : ""; $m = abs $m;
      my $v = sprintf("%d.%03d", int($m / 1000), $m % 1000); $v =~ s/\.?0+$//; return $s . $v; };
    my (@exceeded, %caps);
    if ($b{"core-hours"} eq "none") {
      $caps{core_hours} = { cap => "none", spent => $fmt->($spent_ch), request => $fmt->($req_ch), remaining => "none", over => JSON::PP::false };
    } else {
      my $cap = milli($b{"core-hours"}, "core-hours");
      my $over = $spent_ch + $req_ch > $cap;
      push @exceeded, "core-hours" if $over;
      $caps{core_hours} = { cap => $fmt->($cap), spent => $fmt->($spent_ch), request => $fmt->($req_ch),
        remaining => $fmt->($cap - $spent_ch), over => $over ? JSON::PP::true : JSON::PP::false };
    }
    if ($b{"disk-bytes"} eq "none") {
      $caps{disk_bytes} = { cap => "none", spent => $spent_disk, request => $req_disk, remaining => "none", over => JSON::PP::false };
    } else {
      my $cap = $b{"disk-bytes"} + 0;
      my $over = $spent_disk + $req_disk > $cap;
      push @exceeded, "disk-bytes" if $over;
      $caps{disk_bytes} = { cap => $cap, spent => $spent_disk, request => $req_disk,
        remaining => $cap - $spent_disk, over => $over ? JSON::PP::true : JSON::PP::false };
    }
    my $end_day = day($b{"end-date"}, "end-date");
    my $date_over = $req_day > $end_day;
    push @exceeded, "end-date" if $date_over;
    $caps{end_date} = { cap => $b{"end-date"}, request => $date, remaining_days => $end_day - $req_day,
      over => $date_over ? JSON::PP::true : JSON::PP::false };
    my $verdict = @exceeded ? "over" : "inside";
    if ($json) {
      print JSON::PP->new->canonical->encode({
        schema => $check_schema, at => $now, budget => $b{id}, covers => $b{covers},
        mode => $b{shadow} eq "on" ? "shadow" : "live", request => $request,
        verdict => $verdict, exceeded => \@exceeded, caps => \%caps,
        spend_records => $records }), "\n";
      exit 0;
    }
    my $c = $caps{core_hours}; my $d = $caps{disk_bytes}; my $e = $caps{end_date};
    my $ok = sub { $_[0]{over} ? "over" : "ok" };
    print "budget: $b{id}\n";
    print "covers: $b{covers}\n";
    print "mode: ", ($b{shadow} eq "on" ? "shadow" : "live"), "\n";
    print "request: $request\n";
    print "verdict: $verdict\n";
    print "exceeded: ", (@exceeded ? join(",", @exceeded) : "none"), "\n";
    print "core-hours: ", $ok->($c), " cap=$c->{cap} spent=$c->{spent} request=$c->{request} remaining=$c->{remaining}\n";
    print "disk-bytes: ", $ok->($d), " cap=$d->{cap} spent=$d->{spent} request=$d->{request} remaining=$d->{remaining}\n";
    print "end-date: ", $ok->($e), " cap=$e->{cap} request=$e->{request} remaining-days=$e->{remaining_days}\n";
  ' -- "$FM_BUDGET_CHECK_SCHEMA" "$FM_BUDGET_SPEND_SCHEMA" "$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}
