# Libraries.dev (SwiftUI ports), vendored

The SwiftUI ports of [Libraries.dev](https://github.com/Jakubantalik/Libraries.dev) by
Jakub Antalik (MIT, see [`LICENSE`](./LICENSE)), vendored at upstream commit `bfcb863`
(2026-10-16). Crok Desktop's own look is built with them (`desktop/macOS/Sources/GrokDesktop/Atelier.swift`):

| Target | Upstream path | Used for |
| --- | --- | --- |
| `MetalFxKit` | `packages/metal-fx/ports/ios/MetalFxKit` | The liquid-metal medallion, the welcome greeting, the send button |
| `BorderBeamKit` | `packages/border-beam/ports/ios/BorderBeamKit` | The beam along the composer while a task works |
| `ThinkingOrbsKit` | `packages/thinking-orbs/ports/ios/ThinkingOrbsKit` | Thinking orbs in place of spinners |
| `VoiceGlowKit` | `packages/voice-glow/ports/ios/VoiceGlowKit` | The glow that rises with the voice while dictating |
| `LibrariesDevSupport` | (Crok) | Finds the compiled shaders; the shared frame-rate cap |

metal-fx's `liquidMetal` material is a port of Paper Shaders (Apache-2.0); see [`NOTICE`](./NOTICE).
Not vendored: the bot avatars, gooey and image ports, the demos, tests and React Native ports.

## Shaders

SwiftPM alone does not compile `.metal` files (Xcode's build system does), so the shaders live
in [`Shaders/`](./Shaders), outside the targets, and [`build-shaders.sh`](./build-shaders.sh)
compiles them into one `LibrariesDev.metallib` for macOS 14 and later.
`desktop/macOS/scripts/build-app.sh` runs it and puts the library in the app's `Contents/Resources`.

It needs Xcode's Metal Toolchain, a separate component since Xcode 26:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Without it the script exits 2, the app is built without the library, and every effect draws its
plain look (`LibrariesDevShaders.isAvailable` is false). Tests and command-line runs find a built
library through `LIBRARIESDEV_METALLIB=<path>`.

## Local patches

Re-apply these when re-vendoring (`git log -- third_party/LibrariesDev` has the history):

1. **Shader library.** `ShaderLibrary.bundle(.module)` reads `LibrariesDevShaders.library`
   (`MetalFx.swift`, `LineBeamLayers.swift`, `RotateBeamLayers.swift`, `PulseBeamLayers.swift`,
   `VoiceGlowLayers.swift`); `VoiceGlowStyle.shadersCompiled` asks `LibrariesDevShaders.isAvailable`.
2. **No SwiftPM resources.** A resource bundle sits at an app bundle's root, where it breaks code
   signing, so `beam-spec.json` is compiled in: `BeamSpecJSON.swift` holds it minified and
   `BeamSpec.shared` decodes that. The original is kept in [`spec/beam-spec.json`](./spec/beam-spec.json);
   regenerate the Swift file by minifying it (`json.dumps(spec, separators=(",", ":"))`) into a
   `##"""` raw string.
3. **Frames.** Every `TimelineView` takes a frame cap from `LibrariesDevShaders` (30 fps:
   `frameInterval` for metal-fx and voice-glow, `beamFrameInterval` for the three beam layers,
   `orbFrameInterval` for `ThinkingOrb`) instead of the display's rate, and metal-fx's honour
   `paused` instead of ticking while still (`MetalFx.swift`, `MetalText.swift`, `MetalBadge.swift`).
   Each frame rebuilds the effect's shapes on the main thread; measured in a debug build, a live
   metal ring cost 64 % of a core at the display's rate and 19 % at 30 fps
   (`desktop/macOS/Tests/GrokDesktopTests/EffectsPerformanceTests.swift`).
4. **macOS.** metal-fx bends with the phone's tilt and a magnet near it; a Mac has neither sensor
   and `CMMotionManager` is unavailable on macOS. `MetalMotionMac.swift` gives the kit a motion
   manager with no data and UIKit's orientation enum there; `MetalMagnet.swift` and `MetalBend.swift`
   name `MetalMotionManager` instead of `CMMotionManager`. On a Mac the pointer bends the ring
   (`source: .pointer`, fed by the app's `MetalPointerFollower`).
5. **MetalText** rasterises its glyphs (an `ImageRenderer` pass on the main thread) only when it
   has a glow, the one thing the glyph points are for.
