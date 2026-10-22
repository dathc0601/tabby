# tabby-sync-server

The account & sync service behind TabbyMac's personal account. It stores, per account, the
salted hashes of two auth keys, the vault's encryption key wrapped by the password and by the
recovery key, and one encrypted snapshot (the vault) with a revision number. Everything is
encrypted on the Mac before upload: the server never sees the password, the recovery key, the
encryption key or the synced data.

- Swift 6, [Hummingbird 2](https://github.com/hummingbird-project/hummingbird), Fluent
  (SQLite for development, Postgres in production).
- The wire format (DTOs, `VaultCrypto`, `SyncSnapshot`) lives in the `TabbySyncProtocol`
  target of the app's package, `../tabby-macos`, and is shared with the app.
- Plain HTTP on one port; TLS is terminated by a reverse proxy (Caddy below).

## API

All routes are under `/v1`, JSON in and out (dates ISO 8601 with milliseconds, binary values
base64). Authenticated routes take `Authorization: Bearer <token>`. Errors are
`{"error": "<code>", "message": "…"}` with codes from `ErrorDTO.Code`.

| Route | Auth | Body → response |
| --- | --- | --- |
| `GET /account/kdf?email=` | – | → `KDFResponse` (unknown emails get stable fake parameters) |
| `POST /account` | – | `RegisterRequest` → 201 `SessionResponse`; 409 if the email exists |
| `POST /session` | – | `SessionRequest` → `SessionResponse` (a new device) |
| `POST /session/recovery` | – | `RecoverySessionRequest` → `RecoverySessionResponse` (recovery-scoped token) |
| `DELETE /session` | full | → 204, signs this device out |
| `GET /account` | any | → `AccountDTO` |
| `PATCH /account/password` | any | `PasswordChangeRequest` → `AccountDTO`; upgrades a recovery token |
| `PUT /account/recovery` | full | `RecoveryRotateRequest` → `AccountDTO` |
| `DELETE /account` | full | `DeleteAccountRequest` → 204 (devices and vault go too) |
| `GET /vault` | any | → `VaultDTO`; 404 when none |
| `GET /vault/head` | full | → `VaultHead`; 404 when none |
| `PUT /vault` | full | `VaultPutRequest` + `If-Match: <revision>` (0 for the first) → `VaultPutResponse`; 409 + `VaultHead` when stale; 428 without `If-Match` |
| `GET /devices` | full | → `[DeviceDTO]` |
| `DELETE /devices/{id}` | full | → 204, revokes that device's token |

`GET /health` answers `ok` for health checks. A recovery-scoped token ("any" above) may only
read the account and the vault and set a new password. `POST /account`, `POST /session` and
`POST /session/recovery` are limited to 10 requests a minute per client address and route
(429 with `Retry-After`). Request bodies are limited to 64 KB, `PUT /vault` to 25 MB.

## Run locally

```sh
cd tabby-sync-server
swift run tabby-sync-server            # http://localhost:8080, SQLite in ./sync.sqlite
swift test                             # in-process tests, SQLite in memory
```

Building needs Swift 6.2 (Xcode 26 or later, or the `swift:6.2` Linux image): Hummingbird 2.28
requires swift-tools 6.2.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Listening port |
| `HOSTNAME` | `0.0.0.0` | Listening address |
| `DATABASE_URL` | – | `postgres://user:password@host:5432/db[?sslmode=disable\|prefer\|require]`; when unset, SQLite is used |
| `SQLITE_PATH` | `./sync.sqlite` | SQLite file (in Docker: `/app/data/sync.sqlite`) |
| `SERVER_SECRET` | random per process | Keys the fake KDF salts for unknown emails; keep it stable. Required when `ENVIRONMENT=production` |
| `ENVIRONMENT` | – | `production` makes a missing `SERVER_SECRET` a startup error |
| `LOG_LEVEL` | `info` | `trace` … `critical` |
| `REGISTRATIONS_PER_DAY` | `20` | New accounts one client address may create per day (registration is open) |

The database schema is created and migrated at startup.

## Docker

The image is built from the repository root because the server depends on `../tabby-macos`:

```sh
docker build -f tabby-sync-server/Dockerfile -t tabby-sync-server .
docker run --rm -p 8080:8080 -v tabby-sync-data:/app/data -e SERVER_SECRET=$(openssl rand -hex 32) tabby-sync-server
```

It is a static Linux build (`--static-swift-stdlib`) on `ubuntu:noble`, running as the
unprivileged user `tabbysync`; without `DATABASE_URL` it keeps SQLite in the `/app/data`
volume.

With Postgres, use `compose.yaml` (also the quickest local server for manual checks; the
app reaches it with `TABBYMAC_SYNC_URL=http://localhost:8080`):

```sh
cd tabby-sync-server
cp .env.example .env                   # then set the two secrets, e.g.:
sed -i '' -e "s/^SERVER_SECRET=.*/SERVER_SECRET=$(openssl rand -hex 32)/" \
          -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env   # GNU sed: -i without ''
chmod 600 .env
docker compose up -d --build
docker compose logs -f server
```

The server is published on `127.0.0.1:8080` only, for the reverse proxy on the same host.

## Deploy behind Caddy at tabby-sync.dcstyle.info

TabbyMac talks to `https://tabby-sync.dcstyle.info` (the constant `SyncClient.defaultURL` in the
app). On the host that runs the compose stack, with a DNS `A`/`AAAA` record for
`tabby-sync.dcstyle.info` pointing at it and ports 80 and 443 open, add to the Caddyfile:

```caddyfile
tabby-sync.dcstyle.info {
	request_body {
		max_size 26MB
	}
	reverse_proxy 127.0.0.1:8080
}
```

and `systemctl reload caddy`. Caddy obtains and renews the certificate itself. It sets
`X-Forwarded-For` to the client's address and (Caddy 2.5 and later), unless
`trusted_proxies` is configured, discards whatever the client sent in that header. The rate
limiter uses the first entry of `X-Forwarded-For`, so do not publish port 8080 to the
internet, or clients can choose their own rate-limit key.

To update: `git pull && docker compose up -d --build` (migrations run at startup).

## Behind Cloudflare (or another CDN)

With the hostname proxied by Cloudflare, the reverse proxy's peer is a Cloudflare edge
server, so `X-Forwarded-For: $remote_addr` (nginx) or Caddy's default would key every rate
limit, and the daily registration cap, on a few hundred Cloudflare addresses shared by all
users. Restore the visitor's address from `CF-Connecting-IP`, trusting it only from
Cloudflare's published ranges, and still overwrite `X-Forwarded-For` (Cloudflare appends to
whatever the client sent, so its first entry can be forged).

nginx (`ngx_http_realip_module`): generate a snippet from Cloudflare's lists and include it in
the `server` block only, so other sites on the host are not affected:

```sh
{ for v in v4 v6; do curl -fsS https://www.cloudflare.com/ips-$v | sed 's/.*/set_real_ip_from &;/'; done
  echo 'real_ip_header CF-Connecting-IP;'; } | sudo tee /etc/nginx/snippets/cloudflare-realip.conf
```

```nginx
server {
    server_name tabby-sync.dcstyle.info;
    include snippets/cloudflare-realip.conf;
    client_max_body_size 26m;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $remote_addr;   # now the visitor, not Cloudflare
    }
    # listen 443 ssl / certificates as before
}
```

`nginx -t && systemctl reload nginx`, then sign in once and check that `docker compose logs
server` shows your own address. Regenerate the snippet when Cloudflare changes its ranges
(rarely).

Caddy 2.7 or later: in the global options set `servers { trusted_proxies static <the ranges
from ips-v4 and ips-v6> client_ip_headers CF-Connecting-IP }` and in the site's
`reverse_proxy` add `header_up X-Forwarded-For {client_ip}`.

Cloudflare's 100 MB request limit (free plan) is above the server's 25 MB vault limit.
`GET` and `HEAD /health` answer `ok` / 200 for uptime checks.

## Backups

Back up the Postgres volume regularly, for example daily from cron:

```sh
docker compose exec -T db pg_dump -U tabby -Fc tabby_sync > tabby-sync-$(date +%F).dump
# restore into an empty database:
docker compose exec -T db pg_restore -U tabby -d tabby_sync --clean < tabby-sync-YYYY-MM-DD.dump
```

With SQLite, copy the file with `sqlite3 /app/data/sync.sqlite ".backup '/app/data/backup.sqlite'"`
rather than `cp` while the server runs.

The dump holds only ciphertext and hashes, but it still allows offline password guessing at
scrypt cost (the KDF salt and the auth-key hash are in it), so keep backups private and
encrypted. Keep `SERVER_SECRET` with them: if it changes, the fake KDF answers for unknown
emails change too (harmless for real accounts, but it lets someone notice which emails exist
by comparing answers from before and after).
