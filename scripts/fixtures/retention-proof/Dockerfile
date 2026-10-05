ARG UBUNTU_BASE_IMAGE=ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b
FROM ${UBUNTU_BASE_IMAGE}

ARG UBUNTU_BASE_IMAGE
ARG UBUNTU_SNAPSHOT=20260918T000000Z
ARG PACKAGE_LOCK_BASE64
ARG PACKAGE_LOCK_SHA256
ARG PACKAGE_PINS_BASE64
ARG PACKAGE_PINS_SHA256
ARG DOCKERFILE_SHA256

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

LABEL org.opencontainers.image.base.name="${UBUNTU_BASE_IMAGE}" \
  com.meet.retention-proof.snapshot="${UBUNTU_SNAPSHOT}" \
  com.meet.retention-proof.packages-sha256="${PACKAGE_LOCK_SHA256}" \
  com.meet.retention-proof.dockerfile-sha256="${DOCKERFILE_SHA256}"

RUN set -euo pipefail; \
    [[ "$UBUNTU_BASE_IMAGE" == "ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b" ]]; \
    [[ "$UBUNTU_SNAPSHOT" == "20260918T000000Z" ]]; \
    [[ "$PACKAGE_LOCK_BASE64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; \
    [[ "$PACKAGE_LOCK_SHA256" =~ ^[0-9a-f]{64}$ ]]; \
    [[ "$PACKAGE_PINS_BASE64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; \
    [[ "$PACKAGE_PINS_SHA256" =~ ^[0-9a-f]{64}$ ]]; \
    [[ "$DOCKERFILE_SHA256" =~ ^[0-9a-f]{64}$ ]]; \
    [[ "$(dpkg --print-architecture)" == amd64 ]]; \
    [[ -s /etc/ssl/certs/ca-certificates.crt ]]; \
    command -v dpkg-deb >/dev/null; \
    printf '%s' "$PACKAGE_LOCK_BASE64" | base64 --decode > /tmp/retention-package-lock.json; \
    [[ "$(sha256sum /tmp/retention-package-lock.json | cut -d' ' -f1)" == "$PACKAGE_LOCK_SHA256" ]]; \
    printf '%s' "$PACKAGE_PINS_BASE64" | base64 --decode > /tmp/retention-package-pins.tsv; \
    [[ "$(sha256sum /tmp/retention-package-pins.tsv | cut -d' ' -f1)" == "$PACKAGE_PINS_SHA256" ]]; \
    [[ "$(wc -l < /tmp/retention-package-pins.tsv)" -eq 115 ]]; \
    sed 's/^\[//; s/\]$//; s/},{/}\n{/g' /tmp/retention-package-lock.json > /tmp/retention-package-lock-entries.jsonl; \
    [[ "$(wc -l < /tmp/retention-package-lock-entries.jsonl)" -eq 115 ]]; \
    : > /tmp/retention-locked-pins.tsv; \
    package_entry_pattern='^\{"name":"([a-z0-9][a-z0-9+.-]*)","sha256":"([0-9a-f]{64})","version":"([A-Za-z0-9.+:~_-]+)"\}$'; \
    while IFS= read -r package_entry; do \
      [[ "$package_entry" =~ $package_entry_pattern ]]; \
      printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" >> /tmp/retention-locked-pins.tsv; \
    done < /tmp/retention-package-lock-entries.jsonl; \
    cmp --silent /tmp/retention-locked-pins.tsv /tmp/retention-package-pins.tsv; \
    declare -A expected_hashes=(); \
    declare -A expected_versions=(); \
    declare -a package_arguments=(); \
    while IFS=$'\t' read -r package version expected_sha256 extra; do \
      [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; \
      [[ "$version" =~ ^[A-Za-z0-9.+:~_-]+$ ]]; \
      [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; \
      [[ -z "${extra:-}" && -z "${expected_hashes[$package]+present}" ]]; \
      expected_hashes["$package"]=$expected_sha256; \
      expected_versions["$package"]=$version; \
      package_arguments+=("$package=$version"); \
    done < /tmp/retention-package-pins.tsv; \
    [[ "${#package_arguments[@]}" -eq 115 ]]; \
    sed -i "/^Signed-By:/a Snapshot: ${UBUNTU_SNAPSHOT}" /etc/apt/sources.list.d/ubuntu.sources; \
    grep -Fq "Snapshot: ${UBUNTU_SNAPSHOT}" /etc/apt/sources.list.d/ubuntu.sources; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o APT::Update::Error-Mode=any update; \
    find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' -delete; \
    apt-get -y --download-only --reinstall --no-install-recommends --allow-downgrades -o Acquire::Retries=1 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 install "${package_arguments[@]}"; \
    shopt -s nullglob; \
    package_archives=(/var/cache/apt/archives/*.deb); \
    [[ "${#package_archives[@]}" -eq 115 ]]; \
    for archive in "${package_archives[@]}"; do \
      package="$(dpkg-deb -f "$archive" Package)"; \
      version="$(dpkg-deb -f "$archive" Version)"; \
      architecture="$(dpkg-deb -f "$archive" Architecture)"; \
      [[ "$architecture" == amd64 || "$architecture" == all ]]; \
      [[ "$version" == "${expected_versions[$package]-}" ]]; \
      expected_sha256="${expected_hashes[$package]-}"; \
      [[ -n "$expected_sha256" ]]; \
      actual_sha256="$(sha256sum "$archive" | cut -d' ' -f1)"; \
      [[ "$actual_sha256" == "$expected_sha256" ]]; \
      unset "expected_hashes[$package]" "expected_versions[$package]"; \
    done; \
    [[ "${#expected_hashes[@]}" -eq 0 && "${#expected_versions[@]}" -eq 0 ]]; \
    apt-get -y --no-download --reinstall --allow-downgrades --no-install-recommends install "${package_arguments[@]}"; \
    jq -e 'length == 115 and all(.[]; (keys == ["name", "sha256", "version"]) and (.name | test("^[a-z0-9][a-z0-9+.-]*$")) and (.version | test("^[A-Za-z0-9.+:~_-]+$")) and (.sha256 | test("^[0-9a-f]{64}$"))) and ([.[].name] == ([.[].name] | unique | sort)) and (["acl", "bash", "coreutils", "findutils", "gawk", "grep", "jq", "python3", "sed", "tar", "util-linux"] - [.[].name] | length == 0)' /tmp/retention-package-lock.json >/dev/null; \
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}=${Version}\n' | awk -F '\t' '$1 ~ /^ii/ { print $2 }' | LC_ALL=C sort > /tmp/retention-installed-packages; \
    jq -r '.[] | "\(.name)=\(.version)"' /tmp/retention-package-lock.json | LC_ALL=C sort > /tmp/retention-locked-packages; \
    cmp --silent /tmp/retention-installed-packages /tmp/retention-locked-packages; \
    while IFS=$'\t' read -r package version expected_sha256; do \
      apt-cache show "$package" | awk -v package="$package" -v version="$version" -v expected_sha256="$expected_sha256" -v architecture="$(dpkg --print-architecture)" 'BEGIN { RS = ""; FS = "\n"; verified = 0 } { package_name = package_version = package_architecture = package_sha256 = ""; for (i = 1; i <= NF; i++) { if ($i ~ /^Package: /) package_name = substr($i, 10); else if ($i ~ /^Version: /) package_version = substr($i, 10); else if ($i ~ /^Architecture: /) package_architecture = substr($i, 15); else if ($i ~ /^SHA256: /) package_sha256 = substr($i, 9); } if (package_name == package && package_version == version && (package_architecture == architecture || package_architecture == "all")) { if (package_sha256 != expected_sha256) exit 1; verified = 1; } } END { if (!verified) exit 1 }' || exit 1; \
    done < <(jq -r '.[] | [.name, .version, .sha256] | @tsv' /tmp/retention-package-lock.json); \
    apt-get clean; \
    find /var/lib/apt/lists -mindepth 1 -type f -delete; \
    rm /tmp/retention-package-lock.json /tmp/retention-package-pins.tsv /tmp/retention-package-lock-entries.jsonl /tmp/retention-locked-pins.tsv /tmp/retention-installed-packages /tmp/retention-locked-packages

ENTRYPOINT ["/src/scripts/fixtures/retention-proof/proof-entrypoint.sh"]
