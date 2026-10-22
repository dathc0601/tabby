# Personal account and sync

TabbyMac's account keeps a person's profiles, groups, settings, SSH passwords and key
passphrases, private key files and known hosts in step across their Macs. The server stores
one encrypted blob per account and never sees a password, a key or a profile.

Code: `Sources/TabbySyncProtocol` (wire format and crypto, shared with the server),
`Sources/TabbyAccount` (client, change tracking, sync engine), `Sources/TabbyApp/Account`
(UI and scheduling), `../tabby-sync-server` (Hummingbird 2 + Fluent).

## Keys

```
masterKey = scrypt(password, salt, N = 2^17, r = 8, p = 1, 32 bytes)   salt and params per account
authKey   = HKDF-SHA256(masterKey, "tabby-auth")    sent at sign-in; the server stores SHA256(authKey ‖ salt)
wrapKey   = HKDF-SHA256(masterKey, "tabby-wrap")    never leaves the Mac
encKey    = 32 random bytes made at sign-up         encrypts the vault
wrappedByPassword = AES-GCM(wrapKey, encKey)        on the server, returned at sign-in
recovery key      = 20 random bytes, shown as 8 groups of 4 Crockford base32 characters
wrappedByRecovery = AES-GCM(HKDF(recovery, "tabby-recovery-wrap"), encKey)
recoveryAuthKey   = HKDF(recovery, "tabby-recovery-auth")   lets the key sign in ("Forgot password?")
vault             = AES-GCM(encKey, snapshot JSON, aad "tabby-vault-v1")
```

A password change re-wraps `encKey`; the vault is not re-encrypted and other Macs stay signed
in. Clients refuse KDF parameters outside sane bounds, so a hostile server can't make them
spend gigabytes. `GET /v1/account/kdf` answers unknown emails with a stable fake salt, so it
does not reveal who has an account.

## HTTP API (`/v1`, HTTPS)

| Call | Body → result |
|---|---|
| `GET /account/kdf?email=` | `{kdf}` |
| `POST /account` | email, authKey, recoveryAuthKey, kdf, both wrapped keys, device → token, account, device (201) |
| `POST /session` | email, authKey, device → token, account, device |
| `POST /session/recovery` | email, recoveryAuthKey, device → a token limited to `GET /account`, `GET /vault`, `PATCH /account/password`, plus `wrappedByRecovery` |
| `DELETE /session` | signs this device out |
| `GET /account`, `PATCH /account/password`, `PUT /account/recovery`, `DELETE /account` | account management (password-derived proof required) |
| `GET /vault`, `GET /vault/head` | the blob or its revision; 404 before the first upload |
| `PUT /vault` + `If-Match: <revision>` | compare-and-swap; 409 with the current head when stale, 428 without the header |
| `GET /devices`, `DELETE /devices/{id}` | removing a device revokes its token |

Bearer tokens are 32 random bytes, stored hashed, one per device. Sign-up and sign-in are
rate limited per address. The app talks to `https://sync.dcstyle.info` only; there is no
setting for the server (`TABBYMAC_SYNC_URL` exists for tests and development).

## Snapshot

`SyncSnapshot` (JSON, ISO-8601 dates in milliseconds) has item sections — profiles, groups,
secrets (`ssh:password`, `ssh:key-passphrase`, `account:recovery-key`), key files — each a
list of `{id, modifiedAt, value}` plus tombstones `{id, deletedAt}`, and text sections —
settings (canonical JSON of the user config minus `profiles`, `groups`, `account` and
`appearance.dockScreen`) and known_hosts.

Local data carries no timestamps, so `ChangeTracker` (persisted as `sync-state.json`) keeps a
hash per item, stamps an item when its hash changes and leaves a tombstone when one goes
away.

## Merge and sync

`SyncMerger.merge(local:remote:)`: items by id, the newer of edit and deletion wins (a
tombstone wins a tie, local wins other ties), tombstones expire after 90 days; text sections
take the newer side. Two exceptions in `SyncEngine`: known_hosts is the union of both sides'
lines, and a Mac's first sync with an existing account takes the account's settings.

`SyncEngine.sync()`: collect and stamp this Mac's data → `GET /vault` → decrypt → merge →
write what other Macs changed → upload with `If-Match` when the server lacks something →
on 409, start over (up to four rounds). Parts turned off in Settings keep the server's copy
and leave this Mac alone.

The app syncs at launch, five seconds after a change to the config or the Keychain, when
`GET /vault/head` shows a newer revision (checked every minute) and on Sync now (⌘⇧S).

## Private keys

Keys named by profiles and ssh's default identities (`~/.ssh/id_*`) upload only after the
user says yes to each file once (`account.approvedKeyFiles` / `declinedKeyFiles`). On
another Mac they are written to `<config>/keys/<sha512>` (0600) with an index by original
path. Profiles keep their paths: when a key file is missing, the generated `ssh_config` uses
the synced copy, and synced default identities are added for profiles that name no key.
Signing out with "Remove synced data" deletes those copies; files in `~/.ssh` are never
touched.

## Not in this version

Approving a new Mac from another one, passkeys and GitHub sign-in, email verification and
password-reset email, choosing another server, syncing open tabs.
