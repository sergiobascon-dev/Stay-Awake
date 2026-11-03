# Development

Use Swift 6.2+ on Apple Silicon with macOS 26+.

```sh
./scripts/test-local.sh
./scripts/build-local.sh
```

Keep test state, credentials and generated binaries out of version control.
Tests use temporary files and injected services; do not replace these with real
energy, network or application mutations. Real integration checks require a
reviewed signed build and a supervised session. Do not weaken the signing,
recovery, battery or thermal checks to make a test pass.

Historical upstream automation lives under docs/upstream-github/ and is not an
active release configuration for this project. Preserve the MIT attribution.
