# macos-cua

Prebuilt npm distribution for the `macos-cua` CLI.

## Install

```bash
npm install -g macos-cua
```

This package requires macOS 13 or later and ships a universal binary for both
Apple Silicon and Intel Macs.

## Build

From the repository root, build the universal binary and stage the npm package
contents:

```bash
./scripts/build-npm-package.sh
```

This writes the packaged binary to `npm/bin/macos-cua`.

## Package

From this `npm/` directory, create a local tarball:

```bash
npm pack
```

## Publish

For tagged releases, npm publishing is automated by the GitHub `release.yml`
workflow after the corresponding `v*` tag is pushed and trusted publishing is
configured on npm.

Manual fallback from the repository root:

```bash
./scripts/build-npm-package.sh
npm publish ./npm
```

If you want a final dry run first:

```bash
./scripts/build-npm-package.sh
npm publish --dry-run ./npm
```

## Usage

```bash
macos-cua doctor
macos-cua screenshot /tmp/frontmost.png
macos-cua move 800 400 --precise
macos-cua click 120 73 --precise && macos-cua type "Slack" && macos-cua keypress return
```

For full documentation, see the upstream project README:
[github.com/minpeter/macos-cua](https://github.com/minpeter/macos-cua#readme)
