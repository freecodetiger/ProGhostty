# libghostty-vt Integration Notes

## Current Dependency

Ghostty is tracked as a git submodule:

```bash
git submodule update --init --recursive
```

Current checked source:

```text
Vendor/ghostty @ 0071971b5
```

Ghostty declares Zig `0.15.2` as the minimum required version in `Vendor/ghostty/build.zig.zon`.

## Local Zig Tool

For reproducible local builds without changing the system Zig install, download Zig into `.tools/`:

```bash
mkdir -p .tools
curl -L https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz -o .tools/zig-aarch64-macos-0.15.2.tar.xz
tar -xf .tools/zig-aarch64-macos-0.15.2.tar.xz -C .tools
.tools/zig-aarch64-macos-0.15.2/zig version
```

`.tools/` is intentionally ignored by git.

## ProGhostty Patch

`Vendor/ghostty.patch` carries ProGhostty's small additions to the vendored
Ghostty source. The submodule is pinned to an upstream commit, so a clean
checkout never contains these changes — the patch must be applied after every
`git submodule update` and before building the VT library. CI applies it in both
`ci.yml` and `release.yml`.

```bash
git submodule update --init --recursive
cd Vendor/ghostty
git apply ../ghostty.patch
cd ../..
```

The patch adds `GHOSTTY_TERMINAL_DATA_CURSOR_SEMANTIC_CONTENT` (and its
`getTyped` case) — the cursor semantic state ProGhostty's click-to-position
uses to distinguish a live input prompt from a stale/running command line.

> **Keep `.a` and header in sync.** The rebuilt `libghostty-vt.a` references the
> new enum value. The C shim and the `.a` must come from the same build; a
> rebuilt `.a` without the applied patch (or vice-versa) is undefined behavior,
> since the enum value is read with no runtime bounds check under ReleaseFast.

## Build VT Library

Run from `Vendor/ghostty`:

> `-Doptimize=ReleaseFast` is required. Without it the VT library builds in
> Zig's Debug mode (full runtime safety checks, no optimization), which makes
> `ghostty_terminal_vt_write` thousands of times slower — a bulk burst like
> `seq 1 30000` then stalls the UI for seconds. `-Demit-xcframework=false`
> skips the xcodebuild-only packaging we don't link against (Package.swift uses
> the `.a` directly).

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast
```

With Command Line Tools only, the static/dynamic VT library build succeeds and installs:

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
Vendor/ghostty/zig-out/lib/libghostty-vt.0.1.0.dylib
Vendor/ghostty/zig-out/include/ghostty/vt.h
Vendor/ghostty/zig-out/share/pkgconfig/libghostty-vt.pc
Vendor/ghostty/zig-out/share/pkgconfig/libghostty-vt-static.pc
```

The final `ghostty-vt.xcframework` packaging step currently fails on this machine because `xcodebuild -create-xcframework` requires full Xcode, while `xcode-select` points to Command Line Tools.

## Next Integration Step

Short term:

- Install full Xcode.
- Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- Re-run the VT build command above and confirm `Vendor/ghostty/zig-out/lib/ghostty-vt.xcframework` exists.
- Add a SwiftPM binary target or local linker settings for the VT API.

Long term:

- Study `Vendor/ghostty/macos` and `GhosttyKit.xcframework` generation.
- Keep all full libghostty/GhosttyKit calls isolated in `GhosttyVTBridge`.
- Do not let UI/product code depend on Ghostty C/Zig APIs directly.
