# Test-only SDK extension. Build the verification target and runtime candidate first.
# The product runtime does not gain Nginx/Python/OpenSSL CLI.
ARG TEST_BASE=codexone:tls-base
ARG RUNTIME_IMAGE=codexone:candidate
FROM ${RUNTIME_IMAGE} AS bundle
FROM ${TEST_BASE}
USER 0:0
RUN apt-get update && apt-get install -y --no-install-recommends nginx openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bundle /opt/codexone/web/ /test/web/dist/
USER 10001:10001
ENTRYPOINT ["python3"]
