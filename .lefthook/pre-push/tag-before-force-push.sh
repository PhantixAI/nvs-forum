#!/bin/bash
# Tags the remote's current tip before a force-push overwrites it, so the
# discarded history stays reachable. Runs via lefthook (use_stdin: true is
# required in lefthook.yml or it never forwards git's stdin to this script).
set -e

zero="0000000000000000000000000000000000000000"

while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$remote_sha" = "$zero" ] && continue  # new branch, nothing to protect
  git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null && continue  # fast-forward, not a force-push

  tag_name="backup/$(basename "$remote_ref")-$(date +%Y%m%d-%H%M%S)"
  git tag "$tag_name" "$remote_sha"
  echo "Force push detected on $remote_ref — tagged old tip as $tag_name"
done

exit 0
