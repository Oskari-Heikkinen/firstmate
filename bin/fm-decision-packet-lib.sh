#!/usr/bin/env bash
# fm-decision-packet-lib.sh - decision packets and the decision log for
# captain-held tasks.
#
# bin/fm-captain-hold.sh owns every command and every task mutation; this file
# owns only the two record formats it writes beside the backlog, so the rules
# below have one home.
#
# A DECISION PACKET is the structured form of one captain call: the question,
# its options and the recommendation, the authority the call falls under, the
# evidence and run ids, the prerequisite work with its owner, and - only under
# research's standing authority - a deadline and a default. It is stored at
# <data>/captain-hold/packets/<task-id>.packet and is bound to the hold
# lifecycle it was written for by the task's `Captain hold set:` stamp, so a
# re-held task never inherits an old packet's default. A task without a packet
# behaves exactly as it did before packets existed.
#
# Packet input is one `key: value` per line; blank lines and `#` lines are
# ignored. Keys, with how often each may appear:
#   question: <text>                      exactly once
#   option: <key> <text>                  at least twice; <key> is a slug
#   recommendation: <option-key>          exactly once
#   authority: <slug>                     exactly once
#   evidence: <text>                      any number
#   run: <run-id>                         any number
#   prerequisite: <owner-slug> <text>     any number
#   deadline: <UTC timestamp> | <N>h | <N>d   research-standing only, then required
#   default: <option-key>                 research-standing only, then required
#   on-default: done | release            research-standing only, optional (done)
# Only `authority: research-standing` - research's standing authority to
# approve experiments - may carry a deadline and a default, and its default
# must be the recommended option. Every other authority (product, spend,
# global-default, or anything else) is refused a deadline, a default, and an
# on-default, and keeps waiting for an explicit answer. A relative deadline is
# resolved against the recording time and stored as an absolute UTC timestamp.
#
# The DECISION LOG is <data>/captain-hold/decisions.jsonl: one JSON object per
# line, appended once per outcome (answered, deferred, defaulted, reversed,
# reconciled) with schema fm-decision-log.v1. An append is keyed by task,
# outcome, occurrence, and digest, so a replayed command never logs twice, and
# replaying a command whose append was interrupted fills the gap.
#
# Source this file after bin/fm-wake-lib.sh (for fm_lock_acquire_wait); it
# defines functions only.

FM_PACKET_SCHEMA=fm-decision-packet.v1
FM_DECISION_LOG_SCHEMA=fm-decision-log.v1
FM_PACKET_RESEARCH_AUTHORITY=research-standing

fm_packet_dir() {  # <data-dir>
  printf '%s/captain-hold/packets\n' "$1"
}

fm_packet_path() {  # <data-dir> <task-id>
  printf '%s/captain-hold/packets/%s.packet\n' "$1" "$2"
}

fm_decision_log_path() {  # <data-dir>
  printf '%s/captain-hold/decisions.jsonl\n' "$1"
}

# fm_packet_epoch <UTC YYYY-MM-DDTHH:MM:SSZ | YYYY-MM-DD>: seconds since epoch.
fm_packet_epoch() {
  perl -MTime::Local=timegm -e '
    my $v = shift;
    if ($v =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/) {
      print timegm($6, $5, $4, $3, $2 - 1, $1);
    } elsif ($v =~ /^(\d{4})-(\d\d)-(\d\d)$/) {
      print timegm(0, 0, 0, $3, $2 - 1, $1);
    } else { exit 1; }
  ' -- "$1"
}

# fm_packet_age <seconds>: a compact age such as 4d3h, 5h12m, or 0m.
fm_packet_age() {
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -ge 86400 ]; then
    printf '%sd%sh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then
    printf '%sh%sm' $((s / 3600)) $((s % 3600 / 60))
  else
    printf '%sm' $((s / 60))
  fi
}

# fm_packet_normalize <input-file> <recorded-utc>: validate a packet input and
# print its stored body lines (without the schema, task, and hold-set header).
# On refusal returns 1 with the reason on stderr.
fm_packet_normalize() {
  local out rc=0
  out=$(perl -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($path, $now, $research) = @ARGV;
    sub refuse { print STDERR "$_[0]\n"; exit 1; }
    open(my $f, "<", $path) or refuse("packet file cannot be read: $path");
    local $/; my $text = <$f>; close $f;
    refuse("packet file must not be empty") unless defined $text && $text =~ /\S/;
    refuse("packet file exceeds 16384 bytes") if length($text) > 16384;
    my $slug = qr/[A-Za-z0-9._-]+/;
    my (%one, @options, %option_key, @evidence, @runs, @prereqs);
    my %single = map { $_ => 1 } qw(question recommendation authority deadline default on-default);
    my $n = 0;
    for my $line (split /\n/, $text) {
      ++$n;
      $line =~ s/\r$//;
      next if $line =~ /^\s*(#|$)/;
      $line =~ /^([a-z-]+):[ \t]*(.*?)[ \t]*$/ or refuse("packet line $n is not key: value");
      my ($key, $value) = ($1, $2);
      refuse("packet line $n has an empty $key") if $value eq "";
      refuse("packet line $n holds a control character") if $value =~ /[\x00-\x1f\x7f]/;
      refuse("packet line $n exceeds 1000 characters") if length($value) > 1000;
      if ($single{$key}) {
        refuse("packet key $key may appear only once") if exists $one{$key};
        $one{$key} = $value;
      } elsif ($key eq "option") {
        $value =~ /^($slug)\s+(\S.*)$/ or refuse("option must be <key> <text>: $value");
        refuse("option key $1 appears twice") if $option_key{$1}++;
        push @options, "$1 $2";
      } elsif ($key eq "evidence") {
        push @evidence, $value;
      } elsif ($key eq "run") {
        $value =~ m{^[A-Za-z0-9._:/@-]+$} or refuse("run id must be one token: $value");
        push @runs, $value;
      } elsif ($key eq "prerequisite") {
        $value =~ /^($slug)\s+(\S.*)$/ or refuse("prerequisite must be <owner> <text>: $value");
        push @prereqs, "$1 $2";
      } else {
        refuse("unknown packet key: $key");
      }
    }
    for my $key (qw(question recommendation authority)) {
      refuse("packet needs a $key") unless exists $one{$key};
    }
    refuse("packet needs at least two options") if @options < 2;
    refuse("authority must be a slug: $one{authority}") unless $one{authority} =~ /^$slug$/;
    refuse("recommendation names no option: $one{recommendation}")
      unless $option_key{$one{recommendation}};
    my $deadline;
    if ($one{authority} eq $research) {
      refuse("a $research packet needs a deadline") unless exists $one{deadline};
      refuse("a $research packet needs a default") unless exists $one{default};
      refuse("the default must be the recommended option $one{recommendation}, not $one{default}")
        unless $one{default} eq $one{recommendation};
      my $close = $one{"on-default"} // "done";
      refuse("on-default must be done or release: $close") unless $close eq "done" || $close eq "release";
      $one{"on-default"} = $close;
      $now =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/ or refuse("invalid recording time $now");
      my $now_epoch = timegm($6, $5, $4, $3, $2 - 1, $1);
      my $d = $one{deadline};
      my $epoch;
      if ($d =~ /^([1-9]\d{0,3})h$/) { $epoch = $now_epoch + 3600 * $1; }
      elsif ($d =~ /^([1-9]\d{0,2})d$/) { $epoch = $now_epoch + 86400 * $1; }
      elsif ($d =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/) {
        $epoch = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
        refuse("deadline is not a valid time: $d") unless defined $epoch;
      } else { refuse("deadline must be a UTC YYYY-MM-DDTHH:MM:SSZ time, <N>h, or <N>d: $d"); }
      refuse("deadline $d is not after the recording time $now") unless $epoch > $now_epoch;
      my @t = gmtime($epoch);
      $deadline = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
    } else {
      for my $key (qw(deadline default on-default)) {
        refuse("authority $one{authority} is outside research standing authority, so the packet carries no $key; it waits for an explicit answer")
          if exists $one{$key};
      }
    }
    print "recorded: $now\n";
    print "question: $one{question}\n";
    print "authority: $one{authority}\n";
    print "recommendation: $one{recommendation}\n";
    print "option: $_\n" for @options;
    if (defined $deadline) {
      print "deadline: $deadline\n";
      print "default: $one{default}\n";
      print "on-default: " . $one{"on-default"} . "\n";
    }
    print "evidence: $_\n" for @evidence;
    print "run: $_\n" for @runs;
    print "prerequisite: $_\n" for @prereqs;
  ' -- "$1" "$2" "$FM_PACKET_RESEARCH_AUTHORITY" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# fm_packet_field <packet-file> <key>: the first value of <key>, or empty.
fm_packet_field() {
  sed -n "s/^$2: //p" "$1" 2>/dev/null | head -1
}

# fm_packet_option_text <packet-file> <option-key>: that option's text.
fm_packet_option_text() {
  awk -v k="$2" 'index($0, "option: " k " ") == 1 { print substr($0, length("option: " k " ") + 1); exit }' "$1"
}

# fm_packet_live <packet-file> <task-id> <hold-set>: 0 when the packet is a
# well-formed record written for this task's current hold lifecycle.
fm_packet_live() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(fm_packet_field "$1" schema)" = "$FM_PACKET_SCHEMA" ] || return 1
  [ "$(fm_packet_field "$1" task)" = "$2" ] || return 1
  [ -n "$3" ] && [ "$(fm_packet_field "$1" hold-set)" = "$3" ]
}

# fm_packet_write <data-dir> <task-id> <hold-set> <normalized-body>: replace the
# task's packet atomically.
fm_packet_write() {
  local dir path tmp
  dir=$(fm_packet_dir "$1")
  path=$(fm_packet_path "$1" "$2")
  (umask 077; mkdir -p "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.packet.XXXXXX") || return 1
  if {
    printf 'schema: %s\n' "$FM_PACKET_SCHEMA"
    printf 'task: %s\n' "$2"
    printf 'hold-set: %s\n' "$3"
    printf '%s\n' "$4"
  } > "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# fm_decision_log_append <data-dir> <state-dir> <at> <task> <outcome> <mode>
#   <occurrence> <digest> [<authority> [<default-option>]]
# Appends one record unless one with the same task, outcome, occurrence, and
# digest is already logged. Returns nonzero when the log cannot be written.
fm_decision_log_append() {
  local data=$1 state=$2 at=$3 task=$4 outcome=$5 mode=$6 occurrence=$7 digest=$8
  local authority=${9:-} default=${10:-} log lock rc=0 line
  log=$(fm_decision_log_path "$data")
  (umask 077; mkdir -p "${log%/*}") || return 1
  line=$(perl -MJSON::PP -e '
    my ($schema, $at, $task, $outcome, $mode, $occ, $digest, $authority, $default) = @ARGV;
    my %r = (schema => $schema, at => $at, task => $task, outcome => $outcome,
      mode => $mode, occurrence => $occ + 0, digest => $digest);
    $r{authority} = $authority if length $authority;
    $r{default} = $default if length $default;
    print JSON::PP->new->canonical->encode(\%r);
  ' -- "$FM_DECISION_LOG_SCHEMA" "$at" "$task" "$outcome" "$mode" "$occurrence" "$digest" "$authority" "$default") \
    || return 1
  lock="$state/.decision-log.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ -f "$log" ] && perl -MJSON::PP -ne '
      BEGIN { ($t, $o, $n, $d) = splice(@ARGV, 1); }
      my $r = eval { JSON::PP->new->decode($_) } or next;
      if ($r->{task} eq $t && $r->{outcome} eq $o && $r->{occurrence} == $n && $r->{digest} eq $d) { $found = 1; last; }
      END { $? = $found ? 0 : 1; }
    ' "$log" "$task" "$outcome" "$occurrence" "$digest"; then
    :
  else
    printf '%s\n' "$line" >> "$log" || rc=1
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}
