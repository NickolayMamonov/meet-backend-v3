ARG UBUNTU_BASE_IMAGE
FROM ${UBUNTU_BASE_IMAGE}

# Disabled until the separately reviewed base, snapshot, package closure,
# engine layout, and final image digests are recorded in toolchain.lock.json.
ENTRYPOINT ["/src/scripts/fixtures/retention-proof/proof-entrypoint.sh"]
