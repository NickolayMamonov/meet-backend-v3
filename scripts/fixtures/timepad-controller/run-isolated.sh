#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 COMMAND [ARG ...]" >&2
  exit 2
}

[ "$#" -gt 0 ] || usage
[ "$(timeout 5s uname -s)" = Linux ] || {
  echo "ISOLATION_UNAVAILABLE: Linux is required" >&2
  exit 77
}
[ "$(timeout 5s id -u)" -eq 0 ] || {
  echo "ISOLATION_UNAVAILABLE: root is required" >&2
  exit 77
}

for tool in timeout unshare mount readlink find awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ISOLATION_UNAVAILABLE: required tool is missing" >&2
    exit 77
  }
done

source_root=$(timeout 5s bash -c 'pwd -P')
parent_mount_ns=$(timeout 5s readlink /proc/self/ns/mnt)
parent_network_ns=$(timeout 5s readlink /proc/self/ns/net)
parent_pid_ns=$(timeout 5s readlink /proc/self/ns/pid)

timeout --signal=TERM --kill-after=10s 1800s \
  unshare --mount --net --pid --fork --kill-child \
  bash "$source_root/scripts/fixtures/timepad-controller/isolation-child.sh" \
  "$source_root" "$parent_mount_ns" "$parent_network_ns" "$parent_pid_ns" "$@"
