# Utopia: DeepLethe's published image, unchanged, plus the tools the start wrapper needs.
#
# UTOPIA_IMAGE is a service variable; Railway passes service variables to Docker builds as
# build arguments, so an upgrade is a change of that one variable (tag and digest together).
# The default is release v0.1.0-rc9 (pre-release, 2026-10-11), pinned by its multi-arch index
# digest; the image's amd64 config says revision 888761cae3d7c9432b75164ccd715731ccf2999d,
# the commit tagged v0.1.0-rc9.
ARG UTOPIA_IMAGE=ghcr.io/deeplethe/utopia:0.1.0-rc9@sha256:9bba072bf510519425c141e71642cdfaf085c2b8dfde2b9c35bb8c6a31b95755
FROM ${UTOPIA_IMAGE}

# Debian bookworm's own packages (no vendor repository, no version pins that could vanish):
#   curl              health probe and the first-boot API calls on loopback
#   jq                builds and reads the JSON of those calls (no secrets on command lines)
#   postgresql-client psql: waits for Postgres, manages the utopia_app role, reads bootstrap state
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends curl jq postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && psql --version && curl --version | head -n 1 && jq --version \
    && command -v utopia-server && test -f /app/web-dist/index.html

COPY --chmod=0755 railway-start.sh /usr/local/bin/railway-start
RUN bash -n /usr/local/bin/railway-start

ENV UTOPIA_DATA_DIR=/app/data
EXPOSE 1516
CMD ["/usr/local/bin/railway-start"]
