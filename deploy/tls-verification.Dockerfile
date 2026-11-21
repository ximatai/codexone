# Test-only runtime extension. Build or load the runtime candidate first.
# The product runtime does not gain Nginx/Python/OpenSSL CLI.
ARG TEST_BASE=ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
ARG RUNTIME_IMAGE=codexone:candidate
FROM ${RUNTIME_IMAGE} AS bundle
FROM ${TEST_BASE}
USER 0:0
ARG APT_MIRROR=
RUN src=/etc/apt/sources.list.d/ubuntu.sources && cp "$src" /tmp/ubuntu.sources \
    && if [ -n "$APT_MIRROR" ]; then sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" "$src"; fi \
    && (apt-get -o APT::Update::Error-Mode=any -o Acquire::https::Timeout=15 update && apt-get install -y --no-install-recommends nginx openssl python3 libsqlite3-0 \
        || { cp /tmp/ubuntu.sources "$src"; rm -rf /var/lib/apt/lists/*; apt-get -o APT::Update::Error-Mode=any update && apt-get install -y --no-install-recommends nginx openssl python3 libsqlite3-0; }) \
    && rm -rf /var/lib/apt/lists/* && mv /tmp/ubuntu.sources "$src"
COPY --from=bundle /opt/codexone/web/ /test/web/dist/
COPY --from=bundle /usr/local/bin/codexone /output/codexone
USER 10001:10001
ENTRYPOINT ["python3"]
