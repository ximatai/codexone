# Development environment matching the CI backend toolchain (Linux amd64/arm64).
FROM swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63

ARG NODE_VERSION=22.23.0
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git libsqlite3-dev python3 xz-utils \
  && rm -rf /var/lib/apt/lists/*
# Install the pinned Node.js release after checking it against the published checksums.
RUN set -eux; \
  case "$(dpkg --print-architecture)" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac; \
  file="node-v${NODE_VERSION}-linux-${arch}.tar.xz"; \
  cd /tmp; \
  curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${file}"; \
  curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
  grep " ${file}\$" SHASUMS256.txt | sha256sum --check -; \
  tar -xJf "${file}" -C /usr/local --strip-components=1 --no-same-owner; \
  rm -f "${file}" SHASUMS256.txt; \
  node --version
