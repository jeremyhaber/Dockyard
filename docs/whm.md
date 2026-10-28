# WHM servers

Add a WHM server once and Dockyard creates a connection for every cPanel account on it, keeps the list up to date, and opens cPanel for any account without a password.

## 1. Create an API token in WHM

1. In WHM, go to **Development → Manage API Tokens** and click **Generate Token**.
2. Give it a name, such as `Dockyard`.
3. Under privileges, tick only these (the **?** beside the API token field in Dockyard lists them too):
   - **List Accounts** (`list-accts`): needed to sync accounts.
   - **Account Summary** (`acct-summary`): fills in each account's website URLs from its domains and their folders (main, addon and subdomains; parked domains share the main folder). Without it, accounts sync without website URLs.
   - **Create User Session** (`create-user-session`): needed for **Open cPanel** and **Open WHM**. Skip it if you don't want one-click login.
4. Copy the token. WHM shows it only once.

A root token sees every account on the server. A reseller token sees only the accounts that reseller owns.

## 2. Add the server to Dockyard

1. Open **Connections** and choose **Import… → WHM server…**.
2. Fill in:
   - **Host**: your WHM address, such as `whm.example.com`.
   - **API port**: `2087` unless your host changed it.
   - **API user**: `root`, or your reseller username.
   - **API token**: the token from step 1.
   - **Account login**: how the accounts log in. See below.
3. Click **Add and Sync**.

The server appears under **Sources** in the Connections sidebar, with one connection per account. Select it to open a panel on the right with **Open WHM**, **Edit Server…**, **Sync Now** and **Test Login**. Dockyard syncs again every 6 hours (change this in Settings).

Each sync also sets an account's website icon from its main domain and its website URLs from its domains. Once you change either in the account's site editor, syncs leave that field alone.

## 3. Choose how accounts log in

WHM doesn't share account passwords, so pick one of these:

| Account login | What happens |
|---|---|
| **Through root** (easiest) | Dockyard logs in to the server as root with your root key, then works as each account. Nothing to set up per account. |
| **Password** | Dockyard asks for each account's cPanel password the first time you connect, then keeps it in the Keychain. |
| **SSH key** | Every account logs in with one private key. No password prompts. |
| **SSH agent** | Every account logs in with the keys in your SSH agent or 1Password's SSH agent. |

To change it later, open **Import… → WHM server…** again and click **Edit** next to the server. Accounts still using the old login switch to the new one. Accounts whose login you set yourself keep theirs.

### Through root (easiest)

If a key already lets you log in as root (`ssh root@your-server` works without a password), this is all you need:

1. Edit the WHM server and set **Account login** to **Through root**.
2. Choose that private key (the file *without* `.pub`), or **SSH agent** if the key lives in your agent or 1Password. Enter the passphrase if it has one. Not sure which key it is? Click **Find My Root Key**: Dockyard tries the `IdentityFile` keys for that host in `~/.ssh/config`, your SSH agent, 1Password's agent and the keys in `~/.ssh`, and selects the first one root accepts.
3. Click **Test Login**. Dockyard logs in as root, then opens one synced account as that account.
4. Click **Save**.

Every account now connects without a password. For each one, Dockyard logs in as root and then starts the file transfer as that account (`su` to the account user), so:

- Files you upload belong to the account, not root, and permissions work as normal.
- You can only reach what the account itself can reach.
- Accounts don't need shell access.
- The terminal and server-side tasks (zip, extract, search) run as the account too.

Things to know:

- The server must allow root to log in with a key. On cPanel servers that's usually already the case (`PermitRootLogin prohibit-password` or `without-password` in `/etc/ssh/sshd_config`).
- Every account connection relies on that root key. Keep it protected with a passphrase or in 1Password.

### Per-account SSH key

Use this when you can't log in as root. The server has to trust your key in each cPanel account. Being able to log in to WHM or as root with the key isn't enough.

1. **Get a key.** Use one you have, or create one in Terminal:
   ```
   ssh-keygen -t ed25519
   ```
   This makes `~/.ssh/id_ed25519` (private, stays on your Mac) and `~/.ssh/id_ed25519.pub` (public, goes on the server).
2. **Turn on shell access.** In WHM, go to **Account Functions → Manage Shell Access** and give each account **Jailed Shell** (or Normal Shell). SFTP doesn't work without it.
3. **Authorize the key in each account.** In Dockyard, right-click the account and choose **Open cPanel**. In cPanel, go to **Security → SSH Access → Manage SSH Keys**, click **Import Key**, paste the contents of your `.pub` file, and click **Import**. Back in the list, click **Manage** next to the key, then **Authorize**.
4. **Point Dockyard at the private key.** Edit the WHM server, set **Account login** to **SSH key**, click **Choose…** and pick the private key, the file *without* `.pub`. If the key has a passphrase, enter it once. All the server's accounts share it.

If one account still fails, check that the key is authorized in that account and that the account has shell access.

### Password

No setup. Dockyard asks for each account's cPanel password the first time you connect and keeps it in the Keychain.

## Good to know

- Your edits are kept. If you rename an account, change its notes or host, or give it its own login, syncs leave that alone.
- Accounts deleted in WHM aren't deleted in Dockyard. They're marked **Removed from WHM**, and come back if the account does.
- Suspended accounts get a `suspended` tag.
- The API token and key passphrase are stored in the Keychain, never in Dockyard's database.
