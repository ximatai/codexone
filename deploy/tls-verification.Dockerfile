# Test-only runtime extension. Build or load the runtime candidate first.
# The product runtime does not gain Nginx/Python/OpenSSL CLI.
ARG TEST_BASE=swift:6.4.1-noble-slim@sha256:46c3f2b7b5f9ad083a941af264fec95b3dcd66e41885d6458606316c62e0d5c8
ARG RUNTIME_IMAGE=codexone:candidate
FROM ${RUNTIME_IMAGE} AS bundle
FROM ${TEST_BASE}
USER 0:0
RUN apt-get update && apt-get install -y --no-install-recommends nginx openssl python3 libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bundle /opt/codexone/web/ /test/web/dist/
COPY --from=bundle /usr/local/bin/codexone /output/codexone
USER 10001:10001
ENTRYPOINT ["python3"]
