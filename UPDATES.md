# Updates

QuotaTempo uses Sparkle 2 to check the official HTTPS appcast for signed updates. Scheduled checks run at most once per day. QuotaTempo does not send system profiling data, quota values, reset times, provider data, diagnostics, credentials, or usage analytics with an update check.

Use **Check for Updates...** in QuotaTempo to check manually. Sparkle presents the available version and release notes before installation. QuotaTempo does not force silent updates, and automatic installation is disabled.

The canonical download location is the [QuotaTempo releases page](https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/latest). Download the archive and SHA-256 from the same release. Do not download a build from an unofficial mirror.

The public-beta 0.1.x line may receive compatibility, security, privacy, and display fixes. An update may change or remove an acquisition source when an upstream provider interface changes. The delivery model and pricing of future releases or additional features have not been decided. No particular update, feature, support period, or provider compatibility is promised.

The first Sparkle-enabled release must still be installed manually from the canonical release page. Later signed releases can update that installation in place. Homebrew users may alternatively run `brew upgrade --cask quotatempo` after the cask becomes available.

Before a manual update, quit QuotaTempo and keep the previous verified archive as the rollback source until the replacement passes the checks in the user guide. Normalized observations are stored separately under Application Support and are not required for rollback.
