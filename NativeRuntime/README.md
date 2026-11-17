# Pinned Apple llama.cpp wrapper

The b10549 upstream archive used by `mattt/llama.swift` 2.10549.0 did not contain an iOS Simulator slice. CI now prepares a local binary package explicitly:

```sh
brew install cmake ninja xcodegen
scripts/native/prepare_apple_runtime.sh /tmp/jarvis-apple-native
cd ios && xcodegen generate
```

The original checksum-verified device Metal framework is preserved. The simulator library is compiled from exact llama.cpp commit `b2e5e9b28b2484fbf94b543432ece638996a8b97` for the host's actual simulator architecture (CPU backend), using the iOS Simulator SDK. It is genuine inference, not a stub. Build simulator with `ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES`; device builds keep the upstream arm64 slice. `--device-only` prepares the upstream package for Release workflows without building the simulator.

Generated artifacts are ignored by Git. llama.cpp remains MIT-licensed; its upstream archive/source contains the applicable license. This package neither bundles weights nor adds provider credentials or signing keys. The explicit preparation step downloads build dependencies; the iPhone application still has no network AI route.
