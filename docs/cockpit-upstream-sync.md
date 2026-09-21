# Cockpit fork maintenance

This branch integrates upstream `elias8/libghostty` through
`a776e105ac94c2e6b4083a95d283b405e4c863d6` (checked on 2026-09-21).
Both upstream and the previous Cockpit history are retained by the merge.

## Remaining local fixes

| Fix | Original commits | Current implementation |
| --- | --- | --- |
| Recover invalid IME deltas, salvage committed text, and reopen after the frame | `6ddbcad`, `3dc78a4`, `09b7186` | `packages/flterm/lib/src/input/text_input_session.dart` |
| Leave desktop dead keys to IME composition under Kitty | `9be6780` | `packages/flterm/lib/src/view/view_attachment.dart` |
| Leave desktop Super/Cmd + character shortcuts to the application | `0136792` | `packages/flterm/lib/src/view/view_attachment.dart` |
| Encode Ctrl+Space as a control chord under Kitty, not a plain space | (this branch) | `packages/flterm/lib/src/foundation/platform_map.dart` |

The old `KeyboardInputAdapter` was removed upstream. Its local guards now run
before composition routing and terminal encoding in `ViewAttachment`. Ctrl
chords, virtual modifiers and non-character keys retain their terminal behavior.
Recovery now also requests a frame explicitly so that an idle terminal
does not leave the deferred reopen waiting indefinitely.
The recovery patch remains separate from upstream's reconnection of displaced
text input clients: a malformed delta and a stolen connection are different cases.

Regression coverage lives in `test/view/view_attachment_keyboard_test.dart` and
`test/input/text_input_session_test.dart`. Desktop keyboard cases exercise macOS,
Linux and Windows platform routing in Flutter tests. They do not replace testing
with each platform's native keyboard/IME.

Do not reapply the older scroll forwarding, Windows view ID, displaced IME,
Git build isolation or CPU baseline patches: upstream already includes their
solutions. Keep their behavior covered when updating again.

## Testing this revision in Cockpit

For local development, point **both** dependency overrides at this checkout's
`packages/flterm` and `packages/libghostty` directories. For a shared test build,
publish the merge commit on a retained fork ref and resolve both packages to that
same revision. Existing Git overrides will not see an unpublished local commit.
Do not move an existing release tag to perform the update.

Keep the consumer's `libghostty` hook configured with `source: compile` until a
matching prebuilt is deliberately selected. The native source pin is now
`349f026087d948f8f898dca3231ff91438f83ab8`; invalidate stale consumer native assets
when changing pins. This repository's CI specifies Zig 0.16.0. The Dart package
version labels alone do not identify the native ABI or the upstream commit.

Preserve Cockpit's replay/output suppression, initial resize queue, explicit
scrollback size, stable terminal view identity, zoom and font/SGR adaptations
while validating the update. Search and snapshots are now available but require
separate application integration; existing VT replay does not become snapshot
restoration automatically.

Before shipping, exercise physical/virtual keyboard composition on iOS, dead
keys and Cmd/Super shortcuts with Kitty active, Ctrl+C and modified arrows,
focus after another text field, Windows input, TUI wheel/trackpad scrolling,
split/close/move panes, background tabs, zoom, Nerd Fonts and Kitty image resize.

## Package checks

From the repository root:

```sh
flutter pub get
dart format --output=none --set-exit-if-changed packages/flterm packages/libghostty
flutter analyze --no-pub
```

From `packages/flterm`:

```sh
flutter test --exclude-tags golden
```

From `packages/libghostty`:

```sh
flutter test --no-pub
```

Run rendering goldens in the CI-compatible Flutter container, as documented in
`packages/flterm/dart_test.yaml`, and use the existing CI for native platforms
and WebAssembly. Only remove the fork overrides after a distributed upstream
revision contains equivalent fixes and passes Cockpit's integration checks.

## Validation of this integration

Validated on Linux with Flutter 3.47.5 and the new native source revision:

- `flutter analyze --no-pub`: no issues.
- Formatting check of both packages: passed.
- flterm non-golden suite: 1,097 tests passed.
- libghostty native suite using `flutter test --no-pub`: 507 tests passed.
- Focused keyboard/IME suite: 98 tests passed (also included above).
- Git whitespace/conflict checks: passed.

Goldens in the reference container, WebAssembly and physical macOS/Windows/iOS/
Android devices were not exercised in this local run. Platform overrides in unit
tests validate routing logic, not those platforms' native input channels.
