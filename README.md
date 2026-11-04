# devshell-bundles

Release assets only: dev-shell bundles for Claude Code cloud environments,
produced by `scripts/devshell-bundles/` in metacraft-labs/infra (branch
`devshell-bundles`). Each release holds one content-addressed half of a bundle
(`closure-…`, `sources-…`); `latest-<project>-<system>` holds the pointer the
setup script reads, and `tools` holds the setup script itself. Nothing lives
in the git history but this file.
