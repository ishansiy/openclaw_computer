FROM ghcr.io/tunmax/openclaw_computer@sha256:6ff51015b513931288201f495810c4159d16aba977c7c6c8fb86c2124a9de5c3 AS sqlite_build

ARG SQLITE_AUTOCONF_VERSION=3530400
ARG SQLITE_SHA256=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c

RUN set -eux; \
    find /etc/apt -type f -exec sed -i \
      -e 's|https\?://mirrors.tuna.tsinghua.edu.cn/debian-security|https://deb.debian.org/debian-security|g' \
      -e 's|https\?://mirrors.tuna.tsinghua.edu.cn/debian|https://deb.debian.org/debian|g' {} +; \
    apt-get -o Acquire::Retries=3 update; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      build-essential ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    (curl -fsSL --retry 1 --retry-all-errors --connect-timeout 15 --max-time 60 \
       -o /tmp/sqlite.tar.gz \
       "https://sqlite.org/2026/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz" \
     || curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 \
       -o /tmp/sqlite.tar.gz \
       "https://sources.buildroot.net/sqlite/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz"); \
    printf '%s  %s\n' "${SQLITE_SHA256}" /tmp/sqlite.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/sqlite.tar.gz -C /tmp; \
    cd "/tmp/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}"; \
    CFLAGS="-O2 \
      -DSQLITE_ENABLE_FTS3 \
      -DSQLITE_ENABLE_FTS3_PARENTHESIS \
      -DSQLITE_ENABLE_FTS4 \
      -DSQLITE_ENABLE_FTS5 \
      -DSQLITE_ENABLE_RTREE \
      -DSQLITE_ENABLE_GEOPOLY \
      -DSQLITE_ENABLE_COLUMN_METADATA \
      -DSQLITE_ENABLE_UNLOCK_NOTIFY \
      -DSQLITE_ENABLE_DBSTAT_VTAB \
      -DSQLITE_ENABLE_DBPAGE_VTAB \
      -DSQLITE_ENABLE_MATH_FUNCTIONS \
      -DSQLITE_ENABLE_PREUPDATE_HOOK \
      -DSQLITE_ENABLE_SESSION \
      -DSQLITE_SECURE_DELETE \
      -DSQLITE_THREADSAFE=1 \
      -DSQLITE_MAX_VARIABLE_NUMBER=250000" \
      ./configure --prefix=/opt/sqlite-fixed --disable-static; \
    make -j"$(nproc)"; \
    make install

FROM ghcr.io/tunmax/openclaw_computer@sha256:6ff51015b513931288201f495810c4159d16aba977c7c6c8fb86c2124a9de5c3

ARG HERMES_RELEASE=main
ARG HERMES_VERSION=0.22.5
ARG HERMES_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e
ARG HERMES_INSTALLER_SHA256=99cb3691d55019c6973a7acb775a915648666cc24e483ca827a1cdbb3531a674
ARG HERMES_NPM_VERSION=11.19.0

ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome

LABEL org.opencontainers.image.title="Hermes Agent on TunMax OpenClaw Computer" \
      org.opencontainers.image.version="${HERMES_VERSION}" \
      org.opencontainers.image.revision="${HERMES_COMMIT}" \
      org.opencontainers.image.source="https://github.com/ishansiy/openclaw_computer"

RUN set -eux; \
    find /etc/apt -type f -exec sed -i \
      -e 's|https\?://mirrors.tuna.tsinghua.edu.cn/debian-security|https://deb.debian.org/debian-security|g' \
      -e 's|https\?://mirrors.tuna.tsinghua.edu.cn/debian|https://deb.debian.org/debian|g' {} + \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssh-server net-tools \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    rm -rf /root/.hermes/hermes-agent; \
    test -x /usr/bin/google-chrome; \
    npm install --global --no-audit --no-fund "npm@${HERMES_NPM_VERSION}"; \
    test "$(npm --version)" = "${HERMES_NPM_VERSION}"; \
    curl -fsSL --retry 3 --retry-all-errors \
      "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
      -o /tmp/hermes-install.sh; \
    printf '%s  %s\n' "${HERMES_INSTALLER_SHA256}" /tmp/hermes-install.sh | sha256sum -c -; \
    chmod 0755 /tmp/hermes-install.sh; \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    HERMES_HOME=/root/.hermes /bin/bash /tmp/hermes-install.sh \
      --non-interactive \
      --skip-setup \
      --channel main \
      --branch "${HERMES_RELEASE}" \
      --commit "${HERMES_COMMIT}" \
      --skip-browser --skip-computer-use \
      --dir /root/.hermes/hermes-agent; \
    test "$(git -C /root/.hermes/hermes-agent rev-parse HEAD)" = "${HERMES_COMMIT}"; \
    /root/.local/bin/hermes --version | grep -F "${HERMES_VERSION}"; \
    printf '%s\n' docker >/root/.hermes/hermes-agent/.install_method; \
    printf 'release=%s\nversion=%s\ncommit=%s\n' \
      "${HERMES_RELEASE}" "${HERMES_VERSION}" "${HERMES_COMMIT}" \
      >/etc/hermes-image-release; \
    rm -f /tmp/hermes-install.sh

# Bake PM's locked runtime into the image. The compatibility paths remain stable.
RUN set -eux; \
    test -s /root/.hermes/hermes-agent/hermes_cli/web_dist/index.html; \
    for pair in tools:hermes-pm-tools-cache installs:hermes-pm-installs-cache; do \
      source_name="${pair%%:*}"; cache_name="${pair#*:}"; \
      test -d "/root/.hermes/$source_name"; \
      test ! -e "/tmp/$cache_name"; \
      mv "/root/.hermes/$source_name" "/tmp/$cache_name"; \
      ln -s "/tmp/$cache_name" "/root/.hermes/$source_name"; \
    done; \
    /root/.local/bin/hermes --version | grep -F "${HERMES_VERSION}"

ENV HERMES_WEB_DIST=/root/.hermes/hermes-agent/hermes_cli/web_dist

# Match the official Hermes 0.20.5 image's WAL-reset safety fix while keeping
# this Debian 12 desktop base ABI-compatible with the replacement library.
COPY --from=sqlite_build /opt/sqlite-fixed/lib/libsqlite3.so.3.53.4 /usr/local/lib/
RUN set -eux; \
    ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so.0; \
    ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so; \
    printf '/usr/local/lib\n' >/etc/ld.so.conf.d/000-sqlite-fixed.conf; \
    ldconfig; \
    /root/.hermes/hermes-agent/venv/bin/python -c "import sqlite3, sys; \
v = sqlite3.sqlite_version_info; \
sys.exit(f'linked SQLite {sqlite3.sqlite_version} still has the WAL-reset bug') if v < (3, 51, 3) else None; \
db = sqlite3.connect(':memory:'); \
db.execute(\"CREATE VIRTUAL TABLE docs USING fts5(content, tokenize='trigram')\"); \
db.execute(\"INSERT INTO docs VALUES ('hermes')\"); \
sys.exit('SQLite FTS5 trigram self-test failed') if db.execute(\"SELECT count(*) FROM docs WHERE docs MATCH 'erm'\").fetchone()[0] != 1 else None; \
db.close()"

# Keep the current TunMax desktop libraries; run the existing Hermes stack.
COPY runtime-sync-rules.txt /bz/rules.txt
COPY platform-sync-daemon.sh /bz/sync_daemon.sh
COPY sqlite_checkpoint.py /opt/hermes-image/sqlite_checkpoint.py
RUN chmod 0700 /bz/sync_daemon.sh
COPY hermes-desktop-entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh \
    && bash -n /entrypoint.sh \
    && test -s /bz/lib/common.sh \
    && test -s /bz/lib/desktop.sh \
    && printf '%s\n' 'repository=ghcr.io/tunmax/openclaw_computer' \
       'digest=sha256:6ff51015b513931288201f495810c4159d16aba977c7c6c8fb86c2124a9de5c3' > /etc/hermes-base-image

COPY tailscale-entrypoint.sh /tailscale-entrypoint.sh
RUN chmod +x /tailscale-entrypoint.sh
EXPOSE 7860
ENTRYPOINT ["/tailscale-entrypoint.sh"]
