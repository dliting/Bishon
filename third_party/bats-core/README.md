# bats-core (vendored)

Vendored copy of [bats-core](https://github.com/bats-core/bats-core) v1.2.1,
used by `scripts/ci/shell-checks.sh` when system `bats` is unavailable.

## Why vendored?

Internal CI environments may not have access to:
- `apt-get` mirrors (offline / restricted networks)
- GitHub for source install

Committing bats-core (~50KB of bash scripts, no compilation needed) makes
the repo self-contained: any CI runner with bash 4+ can run shell checks.

## Update

To upgrade bats-core:

```bash
# From repo root
VER=<new-version>
curl -L https://github.com/bats-core/bats-core/archive/refs/tags/v${VER}.tar.gz | \
    tar -xz -C third_party/bats-core --strip-components=1
echo "$VER" > third_party/bats-core/VERSION
```

## License

MIT — see LICENSE.md. Copyright (c) 2017 bats-core contributors.
