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
  bash -c '
    set -euo pipefail
    source_root=$1
    parent_mount_ns=$2
    parent_network_ns=$3
    parent_pid_ns=$4
    shift 4

    check() {
      if ! "$@"; then
        printf 'ISOLATION_UNAVAILABLE: failed isolation assertion:' >&2
        printf " %q" "$@" >&2
        printf "\n" >&2
        exit 77
      fi
    }

    check_private_tmpfs() {
      local target
      target=$(readlink -f "$1") || return 1
      awk -v path="$target" '\''
        $5 == path {
          found = 1
          for (i = 7; i <= NF; i++) {
            if ($i ~ /^(shared|master):/) bad = 1
            if ($i == "-") {
              filesystem = $(i + 1)
              break
            }
          }
        }
        END { exit !(found && filesystem == "tmpfs" && !bad) }
      '\'' /proc/self/mountinfo
    }

    check_private_proc() {
      awk '\''$5 == "/proc" {
        found = 1
        for (i = 7; i <= NF; i++) {
          if ($i ~ /^(shared|master):/) bad = 1
          if ($i == "-") {
            filesystem = $(i + 1)
            break
          }
        }
      }
      END { exit !(found && filesystem == "proc" && !bad) }'\'' \
        /proc/self/mountinfo
    }

    check_empty_directory() {
      local entry
      entry=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit) || return 1
      [ -z "$entry" ]
    }

    check test "$(readlink /proc/self/ns/mnt)" != "$parent_mount_ns"
    check test "$(readlink /proc/self/ns/net)" != "$parent_network_ns"
    check test "$(readlink /proc/self/ns/pid)" != "$parent_pid_ns"
    check test "$(readlink /proc/self/ns/pid)" = "$(readlink /proc/1/ns/pid)"

    mount --make-rprivate /
    mount -t tmpfs -o mode=755,size=64m,nodev,nosuid tmpfs /var/lib
    mount -t tmpfs -o mode=1777,size=256m,nodev,nosuid tmpfs /tmp
    mount -t tmpfs -o mode=755,size=32m,nodev,nosuid tmpfs /run
    if [ -L /var/run ]; then
      check test "$(readlink -f /var/run)" = /run
    else
      check test -d /var/run
      mount -t tmpfs -o mode=755,size=32m,nodev,nosuid tmpfs /var/run
    fi
    mount -t proc -o nosuid,nodev,noexec proc /proc

    for path in /var/lib /tmp /run /var/run; do
      check check_private_tmpfs "$path"
      check check_empty_directory "$path"
    done

    check check_private_proc
    check test ! -S /run/docker.sock
    check test ! -S /var/run/docker.sock
    check test -z "${DOCKER_HOST:-}"
    check awk '\''NR > 1 { exit 1 }'\'' /proc/net/route
    check awk '\''NF { exit 1 }'\'' /proc/net/ipv6_route
    check awk -F: '\''NR > 2 && NF >= 2 {
      name = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != "lo") found = 1
    }
    END { exit found }'\'' /proc/net/dev

    cd -- "$source_root"
    export TIMEPAD_FIXTURE_PARENT_MOUNT_NS=$parent_mount_ns
    export TIMEPAD_FIXTURE_PARENT_NETWORK_NS=$parent_network_ns
    export TIMEPAD_FIXTURE_PARENT_PID_NS=$parent_pid_ns
    exec timeout --signal=TERM --kill-after=10s 1740s "$@"
  ' _ "$source_root" "$parent_mount_ns" "$parent_network_ns" "$parent_pid_ns" "$@"
