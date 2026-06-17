# GitHub Sync

This checkout is connected to:

```text
https://github.com/PacoZhou1/open-speech-asr
```

`scripts/sync_to_github.sh` pushes the current branch and tags to `origin`.
`scripts/install_auto_sync_hook.sh` installs a local `post-commit` hook that runs
the same sync command after each successful commit.

## Install

```bash
scripts/install_auto_sync_hook.sh
```

The installer writes `.git/hooks/post-commit`. Git hooks live outside the
tracked source tree, so the installation is local to this checkout.

## Manual Sync

```bash
scripts/sync_to_github.sh
```

The script:

- refuses to run outside a Git repository;
- refuses to run from a detached HEAD;
- pushes the current branch to `origin`;
- pushes tags to `origin`;
- warns when the worktree has uncommitted changes.

It does not stage files, commit changes, or bypass `.gitignore`.

## Credentials

This checkout may use a repository-scoped deploy key through local Git config.
The private key is stored under `.git/` and is not committed. If the key is
rotated or removed from GitHub, reinstall credentials or update local Git auth
before relying on automatic sync.
