#!/usr/bin/env bash
# fm-component-map.sh - read a repository's component map: which component skill governs a path.
#
# Usage:
#   fm-component-map.sh check <repo|map>
#   fm-component-map.sh touched <repo|map> <path>...
#   fm-component-map.sh goal <repo|map> <id>
#   fm-component-map.sh review-pack <repo> <base> <head>
#   fm-component-map.sh drift <repo|map>
#   fm-component-map.sh --help
#
# <repo> is a repository's top-level directory; its map is
# <repo>/docs/component-map.json. <map> is a map file: a repository's own map,
# or a home map such as $FM_HOME/config/component-map.json, whose globs are
# absolute and whose skills are SKILL.md paths. docs/component-map.md owns the map schema
# (component-map/v1), the glob syntax, the component roots, the home-local map,
# the skill shape and the metadata.sources pins; this header owns the commands.
#
# check validates the repo map and every skill it names: the schema; that
# each skill exists under .agents/skills/<name>/ or .claude/skills/<name>/ and
# its frontmatter and required sections are valid; that the goal section is
# at most 1,500 characters; that every glob of a non-provisional component
# matches at least one tracked file; that no tracked file is claimed by more
# than six components; and that every tracked file under the map's roots
# belongs to a component. It prints one line per problem, a "note:" line for a
# provisional component whose globs all match now and for a map without roots
# (coverage not checked), and an "ok:" summary when clean. For a home map it
# checks the schema and every skill the same way, but no glob against tracked
# files, since home data is in no repository.
#
# touched prints, for each <path>, one tab-separated line per component that
# claims it, "match<TAB>path<TAB>id<TAB>skill-path<TAB>provisional(0|1)", or
# "unmapped<TAB>path" when none does (including a path outside <repo>).
# A relative path is relative to <repo>, or to the working directory for a
# home map, which matches a path's absolute and symlink-resolved forms. It
# validates no skill, so it stays fast enough for a hook. A repo without a map
# prints nothing and exits 0 (fail open).
#
# goal prints the `## Goal and operating principle` section of component
# <id>'s skill, verbatim; the hook injects this text on a first touch. A skill
# that cannot be read or has no goal section exits 1 and says why on stderr; an
# id the map does not name is a usage error.
#
# review-pack lists the paths `git diff --name-only --no-renames <base>...<head>`
# changed, and for each component they touch prints a block with its id,
# skill path and changed paths, then the skill's `## Review` section verbatim.
# A repo without a map, or a diff touching no component, prints nothing.
# The map and skills are read from <repo>'s working tree, not from <head>.
#
# drift recomputes the sha256 of every metadata.sources pin of every skill the
# map names, for a repo or for a map file (a home map such as
# $FM_HOME/config/component-map.json), and prints one tab-separated line per
# problem: "changed<TAB>ids<TAB>skill<TAB>source<TAB>pinned<TAB>now",
# "vanished<TAB>ids<TAB>skill<TAB>source" (the source does not exist) or
# "unreadable<TAB>ids<TAB>skill<TAB>why" (anything else that stops the read).
# It prints nothing when every pin holds; a repository top level without a map
# exits 0.
#
# Exit codes, the same for every subcommand:
#   0  ran, and nothing is wrong (touched and review-pack: output printed, maybe none).
#   1  ran, and found problems: check problems, drift lines, a review-pack
#      block whose checklist could not be read (the block says why), or a goal
#      that could not be read.
#   2  usage error or could not run: bad arguments, not a repository top
#      level, a failing git command, or an internal error.
#   3  the map is missing (check and goal only) or unusable: unreadable, not JSON, or
#      not schema-valid; one line per problem on stderr names the map.
# A caller that must fail open (such as a hook) treats every non-zero exit
# as "no component context" and never blocks on it.
#
# Read-only: it writes nothing anywhere. bin/fm-component-map.py implements it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') printf 'fm-component-map: missing subcommand (see --help)\n' >&2; exit 2 ;;
esac
exec python3 -I "$SCRIPT_DIR/fm-component-map.py" "$@"
