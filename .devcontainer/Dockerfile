# Development environment matching the CI backend toolchain (Linux amd64/arm64).
FROM swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63

ARG NODE_VERSION=26.13.0
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git libsqlite3-dev python3 xz-utils \
  && rm -rf /var/lib/apt/lists/*
# Checksums from https://nodejs.org/dist/v26.13.0/SHASUMS256.txt (linux x64/arm64 tar.xz).
RUN set -eux; \
  case "$(dpkg --print-architecture)" in \
    amd64) arch=x64; checksum=d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997 ;; \
    arm64) arch=arm64; checksum=406fe3fbde1c054adff8b297c16fdb5af6659db327c1ac8acd46b56ef1af9a92 ;; \
    *) exit 1 ;; \
  esac; \
  file="node-v${NODE_VERSION}-linux-${arch}.tar.xz"; \
  cd /tmp; \
  curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${file}"; \
  echo "${checksum}  ${file}" | sha256sum --check -; \
  tar -xJf "${file}" -C /usr/local --strip-components=1 --no-same-owner; \
  rm -f "${file}"; \
  node --version
