# CodexOne

A personal, self-hosted gateway for your own ChatGPT/Codex subscription accounts, with separate keys for your devices and tools, permission isolation, usage controls, and reliable forwarding.

[中文](README.md) · [Documentation](docs/README.md) · [Project status](STATUS.md)

## Why use it

- Separate keys for each device or tool, with model/image permissions, limits, rotation, and archiving.
- Browser authorization for your own accounts, encrypted credentials, automatic refresh, and quota observations.
- Per-key requests, tokens, estimated costs, and failure diagnostics; missing usage stays unknown.
- Responses HTTP/SSE, WebSocket, warmup, compaction, tools, image generation, and reference-image edits. Possibly executed requests are not automatically replayed.
- Independent master keys, snapshot backups, explicit migrations, and controlled recovery.

## Screenshots

All accounts, models, and requests below are synthetic.

![Overview](docs/assets/overview.png)

![Access keys](docs/assets/keys.png)

## Choose a deployment route

- **LAN (no domain)**: four steps over HTTP on a trusted private network, without Nginx or certificates. Read the [plaintext risks](docs/operations/tls-proxy.md#局域网-http-风险) first.
- **Public access or a domain**: follow the [HTTPS deployment](#deploy-on-your-own-server-https) below with a TLS proxy.

## LAN deployment (no domain)

You need Linux amd64, Docker Engine/Compose v2, Python 3, your own subscription, and a fixed private IP on the server (`192.168.1.10` below is an example to replace). **This feature is unreleased; the v0.26.1 image does not support LAN mode.** First [build from source](docs/guide/linux-installation.md#从源码构建) in a checkout containing this feature and put its full immutable image ID in `CODEXONE_IMAGE_ID`. Once released, an image containing the feature can be used directly.

### 1. Initialize

Run from the source directory; the private installation directory must be new and outside the checkout:

```sh
python3 deploy/init-install.py ../codexone-private --image "$CODEXONE_IMAGE_ID" --lan 192.168.1.10
cd ../codexone-private
```

The installer prints the risk, admin URL, and client `base_url`. Non-root users default to their current UID/GID; when running as root, add `--uid 10001 --gid 10001`. Only literal addresses in 10/8, 172.16/12, 192.168/16, 100.64/10, or fc00::/7 are accepted; hostnames, public addresses, and wildcards are refused. Optionally narrow sources with `--lan-allow 192.168.1.0/24`; most users can omit it. `--lan` and `--origin` are mutually exclusive.

### 2. Configure models

Edit `secrets/pool.json`, replacing `configure-model-before-use` with a model available to your subscription. Use 0 for unknown rates. See [configuration fields](docs/guide/configuration.md).

### 3. Check and start

```sh
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py up -d
python3 compose-install.py ps
```

### 4. Open the admin page

Run `cat secrets/admin` on the server, open `http://192.168.1.10:18081`, and sign in as `admin` with that secret. Follow the [admin guide](docs/guide/admin.md) to authorize and enable your own account, then create a device Key. Set `base_url = "http://192.168.1.10:18080/backend-api/codex"` as described in [client setup](docs/guide/client-setup.md#局域网-http). Readiness being 503 before enabling an account is normal. See [switching modes](docs/guide/linux-installation.md#切换局域网与-https).

## Deploy on your own server (HTTPS)

These steps deploy the current release, [v0.26.1](https://github.com/ximatai/codexone/releases/tag/v0.26.1), on a fresh Linux server. Expect 20–30 minutes, mostly for HTTPS certificates and account authorization.

### 0. Prerequisites

| What | Notes |
| --- | --- |
| A Linux amd64 server | Docker Engine with Compose v2 (`docker compose version` works), Python 3, Git. Docker Desktop on macOS/Windows is not supported. |
| Two HTTPS domains | One for clients (the **data domain**, e.g. `gateway.example.com`) and one for the browser admin page (the **admin domain**, e.g. `admin.example.com`), both pointing at the server with trusted certificates. |
| Nginx | Terminates TLS on the host and forwards to the loopback-only gateway. |
| Your own ChatGPT subscription | Authorized later in the admin page. |

### 1. Get the deployment tools and the image

The deployment scripts ship with the source; the image comes from GHCR:

```sh
git clone --depth 1 --branch v0.26.1 https://github.com/ximatai/codexone.git
cd codexone
docker pull ghcr.io/ximatai/codexone:0.26.1
CODEXONE_IMAGE_ID="$(docker image inspect ghcr.io/ximatai/codexone:0.26.1 --format '{{.Id}}')"
echo "$CODEXONE_IMAGE_ID"   # a full ID starting with sha256:
```

The installation is pinned to this immutable ID, so later tag changes cannot affect it. See [release verification](docs/development/releasing.md) to check provenance, or [build from source](docs/guide/linux-installation.md).

### 2. Initialize the installation directory

The installation directory holds all private configuration and secrets. It must be outside the source checkout and must not exist yet:

```sh
python3 deploy/init-install.py ../codexone-private \
  --image "$CODEXONE_IMAGE_ID" --origin https://admin.example.com
cd ../codexone-private
```

- `--origin` is the exact address you will open the admin page with (`https://` + admin domain). Sign-in fails if it differs.
- When running as root, also pass a non-root runtime user, e.g. `--uid 10001 --gid 10001`; otherwise the current user is used.
- `secrets/admin` is the admin sign-in secret and `secrets/master` the account credential master key. Keep both private and out of any repository.

### 3. Configure models

Edit `secrets/pool.json` and replace the example model with model names your subscription offers in the Codex client. Rates only drive local cost estimates (micro-dollars per million tokens); use 0 if unsure:

```json
{
  "models": [
    { "id": "<model-name>", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0 }
  ],
  "reservedMicros": 1000000,
  "executionTimeoutSeconds": 1800,
  "upstreamTransport": "http"
}
```

Vision input, image generation and other fields are described in [configuration](docs/guide/configuration.md). Check the result:

```sh
python3 compose-install.py run --rm gateway --check-config
```

### 4. Start the gateway

```sh
python3 compose-install.py up -d
python3 compose-install.py ps
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/health/live    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/health/ready   # 503 is expected for now
```

The gateway listens on loopback only: `127.0.0.1:18080` for data and `127.0.0.1:18081` for admin. Readiness stays 503 until step 6 enables an account. Always operate through `python3 compose-install.py <command>`, not plain `docker compose`.

### 5. Configure HTTPS (Nginx)

1. Copy [deploy/nginx-data.conf](deploy/nginx-data.conf) and [deploy/nginx-admin.conf](deploy/nginx-admin.conf) to `/etc/nginx/snippets/codexone-data.conf` and `/etc/nginx/snippets/codexone-admin.conf`.
2. Following [deploy/nginx.conf.example](deploy/nginx.conf.example), add the two servers inside `http {}` with your domains and certificate paths.
3. Run `nginx -t`, then reload Nginx.

The data domain only forwards client APIs; the admin domain only serves the admin page. To expose only the data endpoint, or to obtain certificates, see [TLS proxy](docs/operations/tls-proxy.md).

### 6. Sign in and authorize your account

1. Run `cat secrets/admin` on the server, open `https://<admin domain>`, and sign in as `admin`.
2. On the Accounts page, add an account and sign in to ChatGPT in your own browser. The browser then lands on a `localhost` page that does not load; this is expected. Copy the full address from the address bar back into the admin page.
3. New accounts start disabled. Check the details and click Enable; `/health/ready` becomes 200.

Authorization and callback addresses are equivalent to login credentials; never share or screenshot them. See [admin panel](docs/guide/admin.md).

### 7. Create a key and connect Codex

On the Access Keys page, create one key per device or tool and choose its models. The key is shown only once; save it right away.

On the client device, put the key in `CODEXONE_API_KEY` and add to the Codex configuration (`~/.codex/config.toml`):

```toml
model = "<model name from step 3>"
model_provider = "codexone"

[model_providers.codexone]
name = "openai"
base_url = "https://<data domain>/backend-api/codex"
wire_api = "responses"
supports_websockets = true
env_key = "CODEXONE_API_KEY"
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "codexone" }
```

Restart Codex Desktop or the CLI, start a new session and send a message. If the request appears under usage in the admin page, the deployment works. The provider name and header are compatibility settings, not official authorization. See [client setup](docs/guide/client-setup.md) for tools and images.

### Troubleshooting

- **`docker pull` is slow or stalls**: if dockerd uses a proxy, make sure it works for `ghcr.io` and `pkg-containers.githubusercontent.com`, or add both to dockerd's `NO_PROXY`.
- **Admin sign-in fails**: the browser address must match `--origin` exactly (scheme, domain, port) and use HTTPS for the HTTPS route. For LAN mode, use the IP and port printed by the installer.
- **Readiness stays 503**: the account must be authorized **and** enabled; the admin overview lists the reason.
- **Upgrades, backups and rollback**: read [backup and upgrades](docs/guide/backup-upgrade.md) before upgrading.

## Requirements and limits

Linux amd64 containers use host networking, loopback listeners by default, and local named volumes behind a host TLS proxy, with opt-in private-address LAN HTTP; the template does not directly support Docker Desktop. Its 768 MiB memory limit is not a minimum host requirement or throughput guarantee. Source development uses macOS 15+, Swift 6.4, Node.js 22.23.0, and Python 3; Linux builds require SQLite development headers.

Single node and administrator only. Full multi-account routing validation remains pending. No billing service, multi-admin RBAC, or high availability. Costs are estimates, quotas are observations, and token/cost limits are not absolute caps. Client-facing body/image recovery caching is not implemented; output recovery after disconnection or restart is not guaranteed. See [compatibility](docs/reference/compatibility.md).

## Documentation

[Installation and configuration](docs/guide/README.md) · [Admin panel](docs/guide/admin.md) · [Backup and upgrades](docs/guide/backup-upgrade.md) · [Migration from codex-lb](docs/guide/migration.md) · [FAQ](docs/guide/faq.md) · [Operations](docs/operations/README.md) · [API and specs](docs/reference/README.md) · [Architecture](docs/architecture/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

Detailed guides are currently in Chinese.

## Disclaimer and risks

CodexOne is an independent, unofficial project, with no affiliation with or endorsement by OpenAI. OpenAI, ChatGPT, and Codex are trademarks of their respective owners.

The gateway accesses upstream services using **official Codex client identifiers and the official OAuth client ID**. This may violate provider terms, trigger risk controls, or restrict your account. Internal endpoints and protocols may change at any time. You must verify the applicable terms, authorization, and account risks yourself. Technical compatibility and the MIT license do not grant access rights to provider services. This project is for your own accounts and devices; it does not grant permission to share subscriptions with others.

## License

[MIT](LICENSE). [Provenance](docs/reference/provenance.md) · [Third-party notices](THIRD_PARTY_NOTICES.md).
