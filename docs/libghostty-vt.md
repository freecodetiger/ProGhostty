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

## Build VT Library

Run from `Vendor/ghostty`:

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=true
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
- Keep all full libghostty/GhosttyKit calls isolated in `LibGhosttyTerminalEngine`.
- Do not let UI/product code depend on Ghostty C/Zig APIs directly.
