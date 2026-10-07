# Claude Code usage comparison

This optional connection shows weekly and five-hour remaining percentages and
reset times reported by a running Claude Code session. It appears separately
under **Claude Code usage**. It never replaces Codex, Claude Automatic or Claude
Desktop observations and never changes W/P, planning or source selection.

The session's account and the provider's observation time are unverified. Values
are comparison-only, even when they resemble the main Claude row. Ordinary
Desktop Chat and Cowork are not supported by this route. Provider changes may
prevent QuotaTempo from retrieving usage data.

## Requirements

- A signed QuotaTempo distribution with the bundled comparison plugin.
- A running Code session with Mods support. The supported setup tool requires
  the official Claude Code **2.1 series, 2.1.287 or later**.
- **Node.js 20 or later**, used only when you explicitly run the setup tool.
- One chosen local project whose directory and ancestors are not writable by
  other users. Do not change unrelated directory permissions to bypass a refusal.

CLI and Node.js are setup-tool prerequisites, not new requirements for ordinary
QuotaTempo usage. QuotaTempo does not launch either for this comparison. The
connection itself requires a working Code session, not an open Chrome tab.

## 1. Prepare In QuotaTempo

Enable Claude, expand **Claude Code usage**, choose **Prepare connection**, read
the notice and choose **Agree and prepare**. The progress indicator covers
preparation, not installation. The app verifies its signature and the compiled
plugin checksum, then stages unchanged plugin bytes privately.

Expand **Plugin setup and management** and copy the package directory. This is
not an installation receipt. If the chosen project's `/quotatempo-probe status`
already returns `QuotaTempo probe disconnected.`, skip installation rather than
adding another marketplace or replacing an existing setup.

The preparation expires after 15 minutes. Install first if necessary; then
prepare a fresh connection before continuing to step 3.

## 2. Install For One Project

Use **Terminal**, not the Desktop **Add marketplace** panel. The Desktop panel
does not accept this local directory. Close Code sessions for the chosen project
before installing, updating, disabling or uninstalling its plugin.

Use the management tool shipped inside the signed application; cloning the
source repository is not required. The examples assume `/Applications/QuotaTempo.app`.
Adjust only that path if you installed elsewhere.

Set these paths to your actual project, official CLI binary and the package
directory shown by QuotaTempo. The CLI path must identify the real executable,
not a symbolic link. Resolve an installation symlink with `realpath` if needed.
Never supply a password, provider token or API key.

```bash
PROJECT="/absolute/path/to/your/project"
CLI="/absolute/path/to/the/official/claude/binary"
PACKAGE="/absolute/package/directory/shown/by/QuotaTempo"
TOOLS="/Applications/QuotaTempo.app/Contents/Resources/CodePluginTools"
```

Check `node --version` and `"$CLI" --version` before proceeding. Do not upgrade
an existing CLI automatically or install an unofficial binary. The manager
rejects incompatible versions; a failed operation is not retried automatically.

Create a new private receipt parent once. Use a distinct receipt name for each
project, keep it for future management, and do not pre-create the receipt itself.
If the parent already exists, inspect its ownership and permissions rather than
overwriting or relaxing them.

```bash
mkdir -m 700 "$HOME/QuotaTempoCodeManagement"
RECEIPT="$HOME/QuotaTempoCodeManagement/my-project"
```

First inspect the dry-run plan; this does not install anything:

```bash
node "$TOOLS/manage-code-comparison-plugin.mjs" install \
  --project "$PROJECT" --cli "$CLI" --package "$PACKAGE" --receipt "$RECEIPT"
```

Expect `status: planOnly`, `scope: local`, and exactly the selected package's
marketplace-add and install operations. Check the project, executable and package
paths before explicitly applying:

```bash
node "$TOOLS/manage-code-comparison-plugin.mjs" install \
  --project "$PROJECT" --cli "$CLI" --package "$PACKAGE" --receipt "$RECEIPT" \
  --apply --consent-local-management --code-sessions-closed
```

Expect `status: ready` and `completedSteps: 2`. `runtimeAccepted: false` means
installation completed but loading in Code has not yet been established. Local
scope is used for every operation; the official CLI can still maintain a shared
marketplace catalog and cache.

If the tool reports `stopped`, `attentionRequired` or an uncertain operation,
stop. Do not rerun with another receipt, remove the journal or install through a
second route. Preserve the receipt and project journal and use the
[support route](../SUPPORT.md), reporting only the fixed status/reason, not raw
provider files. Partial CLI mutations may already have occurred.

## 3. Verify Loading And Connect

Reopen Code for the exact project. Select `/quotatempo-probe` from Code's slash
command menu and run `status`. Expect the fixed disconnected response:

```text
quotatempo-usage-probe: QuotaTempo probe disconnected.
```

This is a command, not a prompt to the model. If it is absent or the input reaches
the model as an ordinary message, stop and check loading; do not ask the model to
simulate a connection. Reload or reopen the selected Code session after an
installation change.

In QuotaTempo prepare a fresh connection and choose **Copy connection arguments**.
In the registered Code command, submit those exact `connect <directory> <public
key>` arguments. Do not put them in Desktop settings or send them to another
session. Treat the connection arguments as local pairing information; do not
include them in public issues or diagnostic reports.

Code should report `Comparison-only probe connected`. QuotaTempo changes from
**Waiting for Code to connect** to **Connected**, then displays values after a
normal `session.measure` event during genuine work. No extra request solely to
obtain quota data is needed. The **Code observed** time is the local observation
time, not a verified provider refresh timestamp.

## Expiry And Reconnection

Comparison values expire after five minutes without a new distinct quota tuple;
rereading the same tuple does not renew its age. Passed resets also hide values.
Two sessions connected to one receiver stop comparison instead of merging data.
**Refresh** checks the in-memory connection only; it does not force Code or the
provider to measure usage. Idle waiting does not guarantee a measurement.

For an expired preparation, use **Prepare again** and explicitly connect with
the new arguments. Old arguments disappear after handshake or expiry. Restarting
QuotaTempo never restores comparison consent or values; reconnect explicitly.
The normal Codex and Claude rows continue to follow their own acquisition rules.

## Disconnect, Disable And Remove

**Disconnect**, turning Claude off, and normal Quit revoke the receiver and clear
its memory-only values. In Code, `/quotatempo-probe disconnect` stops that session's
export. Disconnecting does not uninstall or disable the plugin.

For management, first disconnect and close the chosen project's Code sessions.
Use the same `PROJECT`, `CLI`, `PACKAGE` and `RECEIPT` as the completed install.
Replace `install` in the dry-run and apply commands with **disable**, **enable**
or **uninstall**. Review each dry run before applying, with both consent flags.
Do not use a wildcard, unqualified plugin ID or global scope.

Disable yields `status: disabled`; enable yields `ready`; uninstall yields
`removed`. Updates preserve disabled state. Uninstall retains plugin data,
marketplace registrations, package bytes and management records because they may
be used elsewhere. QuotaTempo does not remove shared material automatically.
Keep those records if another project still uses the plugin or an operation is
uncertain. Removing the app alone does not uninstall a Code plugin.

### Before Removing QuotaTempo

Uninstall the Code plugin **before** deleting QuotaTempo or its Application
Support data. The manager needs both the bundled tools and the original staged
package even for disable and uninstall.

1. In QuotaTempo choose **Disconnect**. In each selected Code session run
   `/quotatempo-probe disconnect`, then close that project's Code sessions.
2. While QuotaTempo is still installed, use the same `PROJECT`, `CLI`, `PACKAGE`
   and `RECEIPT` from its successful install. Review the **uninstall** dry run,
   then apply with the two consent flags described above. Expect `status: removed`.
3. Repeat for each managed project you intend to remove. If a receipt is missing,
   the package is unavailable or the result is uncertain, stop and use the
   [support route](../SUPPORT.md). Do not recreate a receipt or delete a journal
   to bypass the refusal.
4. Only after those uninstalls complete, follow the
   [app removal guide](user-guide.md#uninstall-and-erase-local-observations).
   Keep package directories and management records used by any other project.
   The tool deliberately retains shared marketplaces, plugin data and records;
   app removal is not permission to delete them broadly.

The bundled privacy copy in version 0.1.12 predates this ordering correction.
For Code removal, follow this current guide rather than deleting the whole
Application Support directory as suggested in that older copy.

## Privacy

Only allowlisted quota and timing metadata cross the local encrypted Unix socket.
Usage and ephemeral private keys remain in memory. The plugin does not read
conversations, provider caches, credentials or account identifiers. There is no
TCP listener, filesystem quota export or telemetry. Package staging and management
store only integrity, path and operation metadata. See the
[privacy contract](../PRIVACY.md#claude-code-usage-comparison) for the precise
boundary and cleanup behavior.
