#!/bin/sh
# Checks commit subjects against Conventional Commits.
# Usage: check-commits.sh --message-file <path> | --range <from..to>
set -eu

pattern='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([A-Za-z0-9_./-]+\))?!?: [^ ].*$'
max_length=100

case "${1:-}" in
  --message-file) subjects="$(head -n 1 "$2")" ;;
  --range) subjects="$(git log --no-merges --format=%s "$2")" ;;
  *)
    echo "Pass --range <from..to> or --message-file <path>." >&2
    exit 2
    ;;
esac

rejected=0
while IFS= read -r subject; do
  [ -z "$subject" ] && continue
  if ! printf '%s\n' "$subject" | grep -Eq "$pattern" || [ "${#subject}" -gt "$max_length" ]; then
    echo "Not a Conventional Commit subject: \"$subject\"" >&2
    rejected=1
  fi
done <<SUBJECTS
$subjects
SUBJECTS

if [ "$rejected" -ne 0 ]; then
  echo 'Write "<type>(<scope>): <summary>", for example "feat(runtime): add mailboxes".' >&2
  exit 1
fi
