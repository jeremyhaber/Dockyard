# 1Password

Dockyard can import sites from 1Password, take secrets from 1Password at connect time instead of the Keychain, and authenticate SFTP through the 1Password SSH agent.

## Setup

1. Install the 1Password desktop app and the CLI: `brew install --cask 1password-cli` (Dockyard looks for `op` in `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`).
2. In 1Password, open Settings > Developer and turn on **Integrate with 1Password CLI**. `op` then unlocks through the app (Touch ID); no `op signin` and no token on disk.
3. For the SSH agent, turn on **Use the SSH agent** in the same pane. Dockyard connects to `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` (`AgentSocket.onePasswordDefaultPath`). Keys stay in 1Password and each use is approved there.

`OnePasswordCLI.status()` reports `notInstalled`, `integrationOff` (no account visible to the CLI), `signedOut` (app locked) or `ready`.

## What Dockyard reads

Only when you ask (import, or connecting with a reference):

| Command | Used for |
| --- | --- |
| `op account list --format json`, `op whoami --format json` | status |
| `op vault list --format json` | vault picker |
| `op item list --vault V --categories Server,Login,"SSH Key" --format json` | import listing (no field values) |
| `op item get ID --vault V --format json` | import preview (host, port, user, references) |
| `op read --no-newline op://...` | a secret at connect time, or one-time copy at import |

Import maps:

- **Server**: host from the `url`, `server`, `hostname`, `host` or `ip address` field (a `sftp://`, `ftp://` or `ftps://` URL also sets protocol, port and folder), `port` field, username and password fields. SFTP is assumed when nothing says otherwise.
- **Login**: the first URL with `sftp://`, `ftp://` or `ftps://`, else the first URL with a host (a web URL's port is ignored).
- **SSH Key**: with a URL it becomes an SFTP site that uses the 1Password agent. Without one it is listed as an available key, and SFTP sites from the same scan use the agent. The private key is never exported.

Options: client folder from the vault or the first tag; secrets as references (default) or copied into the Keychain; agent on/off (default: on when the scan finds SSH Key items). Re-importing updates the connections it created (matched by 1Password item id) and leaves name, notes, host and port alone when you edited them.

## Secret references

A connection can hold a reference per purpose (`password`, `keyPassphrase`, `elevationPassword`), e.g. `op://Infrastructure/Acme web01/password`. `ResolvingSecretStore` wraps the Keychain store: if the connection has a reference for the requested purpose it runs `op read`, otherwise (or if that fails and the Keychain has a value) it uses the Keychain. Rotating the password in 1Password takes effect on the next connect.

By default nothing is cached. `ResolvingSecretStore.Options(cacheTTL:)` keeps resolved values in memory for a few seconds (stored as bytes and zeroed on expiry or `flushCache()`); concurrent connects to one site share a single `op read`, so one Touch ID prompt.

## Privacy

- References are stored in the connection database (`secretReferences`, with the 1Password item id). They are not secrets but are kept out of logs.
- Secret values are never written to SQLite, the log stream or disk. `OnePasswordCLI` logs only the subcommand (`op read` is logged without its reference), error messages come from `op`'s stderr only, and item/field `description`s hide concealed values.
- `op` talks to the desktop app, which decides what to unlock. Dockyard passes arguments as an argv array (no shell) and refuses references that do not start with `op://`.
- Copy-to-Keychain reads each password once during import and then behaves like any Keychain secret.

## In the app

- **Settings, 1Password**: CLI status (installed, integration on, unlocked) with a checklist and Retry when it is not ready, and whether the agent socket exists.
- **Connections, Import, 1Password...**: pick vaults, read the items with progress, review (new, updated, already saved, warnings, SSH keys found) and choose the client folder (none, vault, first tag), "Keep passwords in 1Password" or "Copy into Keychain", and "Use 1Password SSH agent for SFTP". The options re-map the items already read. The sidebar shows a 1Password row once something was imported; its context menu and banner offer Re-import.
- **Site editor**: each secret (password, key passphrase, elevation password) has a "from" menu, Keychain or 1Password. A reference is validated with `OnePasswordCLI.isValidReference`; Choose... walks vault, item, field and inserts the reference. "SSH agent" has an Agent menu: System, 1Password, Custom path.
- Resolved secrets stay in memory for 10 seconds (shared by concurrent connects), and `flushCache()` runs on sleep, screen lock and when a connection is saved.
- Finder mounts try `op` from the sandboxed extension; if the sandbox blocks it, a Keychain copy is used when there is one (choose "Copy into Keychain" for mounted sites).
