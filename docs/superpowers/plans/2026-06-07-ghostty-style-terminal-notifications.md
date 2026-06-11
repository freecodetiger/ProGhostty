# Ghostty-Style Terminal Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ghostty-style terminal notifications so terminal programs and long-running shell commands can prompt the user when attention is needed, including Codex/Claude Code waiting-for-input moments when they emit a terminal signal.

**Architecture:** Keep notification semantics out of the renderer. Parse terminal OSC and BEL control signals in `ProGhosttyCore`, convert them into typed `TerminalEvent` values, let `AppModel` apply notification policy, and send macOS notifications from `ProGhosttyApp`. Match Ghostty's compatible entry points first: OSC 9/iTerm2 notifications, OSC 777/rxvt notifications, OSC 133 command lifecycle markers, and terminal BEL attention events. Codex/Claude-specific behavior must be handled at the signal-emission boundary through native hooks, shell integration, or a wrapper, not by scanning rendered terminal text.

**Tech Stack:** Swift, AppKit, UserNotifications, existing `OscParser`, `TerminalEvent`, `PTYTerminalSessionManager`, `AppModel`, Swift Testing.

---

## Implementation Status

- [x] ProGhostty parses Ghostty-compatible desktop notification OSCs:
  - `OSC 9;<body>`
  - `OSC 777;notify;<title>;<body>`
- [x] ProGhostty parses Ghostty shell-integration command lifecycle markers:
  - `OSC 133;C`
  - `OSC 133;D;<exitCode>`
  - `OSC 133;A`
- [x] ProGhostty parses standalone terminal BEL bytes as attention events.
- [x] ProGhostty ignores OSC terminator BEL bytes so `OSC 9/777` do not double-trigger bell notifications.
- [x] PTY output emits typed semantic events:
  - `TerminalEvent.desktopNotification`
  - `TerminalEvent.commandFinished`
  - `TerminalEvent.bell`
- [x] App policy and macOS delivery live in `ProGhosttyApp`, not in the renderer.
- [x] Foreground app notifications are explicitly presented through `UNUserNotificationCenterDelegate`.
- [x] Settings expose desktop notification, terminal bell, and command-finish notification policy.
- [x] Parser, PTY event, settings, and policy tests are covered.
- [x] Renderer path remains untouched by this feature.
- [x] Interactive Codex recognizes the repo-local `Stop` hook and runs it when a turn completes.
- [ ] Visible macOS notification is manually confirmed in ProGhostty after notification permission/policy are enabled.

## Execution Phases

1. **Terminal-native receive path**
   - Parse `OSC 9;<body>` and `OSC 777;notify;<title>;<body>` as desktop notification requests.
   - Parse standalone `BEL` as a terminal attention request.
   - Parse `OSC 133;C/D/A` as command lifecycle state.
   - Emit typed `TerminalEvent` values before output reaches the renderer.

2. **App-level policy and delivery**
   - Keep macOS notification authorization and delivery in `ProGhosttyApp`.
   - Add settings for desktop notifications, terminal bell behavior, command-finish behavior, minimum command duration, and action type.
   - Rate-limit duplicate notifications so hostile or noisy terminal output cannot spam the system.

3. **Agent waiting-input signal**
   - Prefer existing terminal protocols: BEL, OSC 9, or OSC 777.
   - For Codex, use the `Stop` hook to write an OSC notification to the controlling TTY and return valid hook JSON on stdout.
   - For Claude Code, use its equivalent hook/event system if available; otherwise rely on BEL/OSC emitted by the CLI or a wrapper.
   - Treat hook integration as successful only after manual or automated verification inside the interactive app.

4. **Guardrails**
   - Do not add renderer dependencies on notifications.
   - Do not infer completion by matching text like "waiting for input" in the rendered grid.
   - Do not read private agent config files during setup or tests.
   - Keep all agent-specific logic outside the core rendering path.

### Codex Waiting-Input Integration

The ProGhostty side now supports the Ghostty-style notification protocols and
terminal BEL attention signal. This covers the common terminal-native path used
by CLI programs to request attention after work completes.

If Codex/Claude Code emit BEL when they finish a turn and wait for input,
ProGhostty will now trigger the configured terminal bell notification without
touching the renderer.

For Codex specifically, this repo also installs a project-local `Stop` hook:

- `.codex/hooks.json`
- `.codex/hooks/proghostty_codex_stop_notify.sh`

The hook writes the OSC notification to `/dev/tty` and returns hook JSON on
stdout. This matters because Codex consumes hook stdout as protocol data; writing
escape sequences to stdout would corrupt the hook response.

The hook writes to `${PROGHOSTTY_NOTIFY_TTY:-/dev/tty}` and returns only
`{"continue":true}` on stdout. Do not gate this on `TERM_PROGRAM`; Codex hook
processes may not inherit terminal-identifying environment variables.

Codex may require the project hook to be trusted through its hook trust flow
before it runs in normal interactive sessions. For one-off verification, Codex
also exposes `--dangerously-bypass-hook-trust`, but that should not be the normal
user-facing path.

End-to-end Codex validation has two parts. First, interactive Codex must load
and execute the repo hook when a turn completes. Second, ProGhostty must display
the resulting desktop notification with the user's current macOS notification
permission and app policy.

`codex exec --dangerously-bypass-hook-trust` is not enough evidence for this
feature. On Codex CLI `0.137.0`, automated `exec` probes did not run the
repo-local project hook even when hooks were enabled and the project config
shape was valid. Interactive TUI validation is required.

If native hooks cannot reliably represent "waiting for user input", add a small
agent-status protocol as a semantic OSC event. Keep it separate from privileged
`pg` control commands and keep it out of the render path.

---

## Scope

This plan implements three Ghostty-style behaviors:

1. Program-triggered desktop notifications:
   - `OSC 9;<body>` means show a desktop notification with an empty/custom default title and body `<body>`.
   - `OSC 777;notify;<title>;<body>` means show a desktop notification with the supplied title and body.

2. Shell command-finish notifications:
   - Use existing Ghostty shell integration markers:
     - `OSC 133;C` command starts.
     - `OSC 133;D;<exitCode>` command finishes.
     - `OSC 133;A` prompt starts again.
   - Notify only when the command ran long enough and policy allows it.

3. Terminal bell attention notifications:
   - Standalone `BEL` (`0x07`) means the terminal program asks for attention.
   - `BEL` used as an OSC terminator must not trigger a terminal bell event.
   - This is the most likely Ghostty-compatible path for Codex-style "work finished, waiting for input" prompts when the CLI itself emits a terminal bell.

This plan does not infer Codex or Claude Code "waiting for input" by scanning rendered text. If those tools emit neither BEL nor OSC 9/777 notifications, ProGhostty can support them later through a dedicated agent protocol or wrapper hook.

## Design Decisions

- Notifications are terminal semantics, not rendering behavior.
- `OscParser` stays generic and returns raw `OscSequence`.
- New typed parsers convert raw OSC into domain events:
  - `TerminalDesktopNotificationParser`
  - `TerminalCommandLifecycleParser`
- `TerminalBellParser` parses raw PTY bytes separately so standalone BEL is surfaced while OSC terminator BEL is ignored.
- `TerminalEvent` gains semantic cases instead of forcing `AppModel` to parse raw OSC.
- The notification sender is a protocol so tests can use a recording fake and the app can use `UNUserNotificationCenter`.
- The macOS sender installs a foreground presentation delegate. Codex usually returns to waiting input while ProGhostty is still active, so relying on background notification behavior alone is insufficient.
- Desktop notifications are rate-limited and duplicate-suppressed to avoid hostile or noisy terminal programs.
- Terminal bell notifications default to Ghostty-like conservative behavior: only unfocused sessions and desktop notification enabled.
- Command-finish notifications default to Ghostty-like conservative behavior: only unfocused sessions, only after 5 seconds, bell enabled, desktop notification disabled unless explicitly enabled.

## Files

- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalDesktopNotification.swift`
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalCommandLifecycle.swift`
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalBellParser.swift`
- Create: `Sources/ProGhosttyApp/TerminalNotificationCenter.swift`
- Create: `.codex/hooks.json`
- Create: `.codex/hooks/proghostty_codex_stop_notify.sh`
- Modify: `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/Settings/AppSettings.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Modify: `Sources/ProGhosttyApp/UI/SettingsView.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalNotificationParserTests.swift`
- Test: `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`
- Test: `Tests/ProGhosttyAppTests/TerminalNotificationCenterTests.swift`

---

### Task 1: Parse Ghostty-Compatible Desktop Notification OSCs

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalDesktopNotification.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalNotificationParserTests.swift`

- [ ] **Step 1: Write failing parser tests**

Add this test file:

```swift
import Testing

@testable import ProGhosttyCore

@Suite("Terminal notification OSC parsers")
struct TerminalNotificationParserTests {
  @Test func parsesOsc9AsDesktopNotificationBody() {
    let sequence = OscSequence(raw: "9;Codex finished", command: "9", parameters: ["Codex finished"])

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification == TerminalDesktopNotification(
      title: "ProGhostty",
      body: "Codex finished",
      source: .osc9
    ))
  }

  @Test func parsesOsc777NotifyAsDesktopNotificationTitleAndBody() {
    let sequence = OscSequence(
      raw: "777;notify;Codex;Waiting for input",
      command: "777",
      parameters: ["notify", "Codex", "Waiting for input"]
    )

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification == TerminalDesktopNotification(
      title: "Codex",
      body: "Waiting for input",
      source: .osc777
    ))
  }

  @Test func keepsSemicolonsInsideOsc777NotificationBody() {
    let sequence = OscSequence(
      raw: "777;notify;Claude Code;Done; review changes",
      command: "777",
      parameters: ["notify", "Claude Code", "Done", " review changes"]
    )

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification?.title == "Claude Code")
    #expect(notification?.body == "Done; review changes")
  }

  @Test func ignoresEmptyOrUnknownDesktopNotificationOscs() {
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "9;", command: "9", parameters: [""])
    ) == nil)
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "777;unknown;Title;Body", command: "777", parameters: ["unknown", "Title", "Body"])
    ) == nil)
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "777;notify;Title", command: "777", parameters: ["notify", "Title"])
    ) == nil)
  }

  @Test func trimsAndLimitsDesktopNotificationText() {
    let longBody = String(repeating: "x", count: 600)
    let sequence = OscSequence(raw: "9;\(longBody)", command: "9", parameters: [longBody])

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification?.body.count == 300)
  }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
swift test --filter TerminalNotificationParserTests --no-parallel
```

Expected: build fails because `TerminalDesktopNotificationParser` and `TerminalDesktopNotification` do not exist.

- [ ] **Step 3: Add the desktop notification parser**

Create `Sources/ProGhosttyCore/TerminalCore/TerminalDesktopNotification.swift`:

```swift
import Foundation

public struct TerminalDesktopNotification: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case osc9
    case osc777
  }

  public var title: String
  public var body: String
  public var source: Source

  public init(title: String, body: String, source: Source) {
    self.title = title
    self.body = body
    self.source = source
  }
}

public enum TerminalDesktopNotificationParser {
  private static let maxTitleLength = 120
  private static let maxBodyLength = 300

  public static func parse(_ sequence: OscSequence) -> TerminalDesktopNotification? {
    switch sequence.command {
    case "9":
      guard let body = normalized(sequence.parameters.joined(separator: ";"), limit: maxBodyLength) else {
        return nil
      }
      return TerminalDesktopNotification(title: "ProGhostty", body: body, source: .osc9)

    case "777":
      guard sequence.parameters.count >= 3, sequence.parameters[0] == "notify" else {
        return nil
      }
      guard let title = normalized(sequence.parameters[1], limit: maxTitleLength) else {
        return nil
      }
      let rawBody = sequence.parameters.dropFirst(2).joined(separator: ";")
      guard let body = normalized(rawBody, limit: maxBodyLength) else {
        return nil
      }
      return TerminalDesktopNotification(title: title, body: body, source: .osc777)

    default:
      return nil
    }
  }

  private static func normalized(_ value: String, limit: Int) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit))
  }
}
```

- [ ] **Step 4: Verify parser tests pass**

Run:

```bash
swift test --filter TerminalNotificationParserTests --no-parallel
```

Expected: all parser tests pass.

---

### Task 2: Emit Typed Desktop Notification Events From PTY Output

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalNotificationParserTests.swift`

- [ ] **Step 1: Add a manager-level event test**

Append to `TerminalNotificationParserTests.swift`:

```swift
@MainActor
@Test func ptySessionManagerEmitsDesktopNotificationEventForOsc9() async throws {
  let registry = PTYTerminalSurfaceRegistry()
  let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
  let session = try manager.createSession(config: TerminalSessionConfig(
    shellPath: "/bin/zsh",
    launchCommand: "printf '\\033]9;Codex finished\\007'; sleep 0.1",
    workingDirectory: nil,
    environment: [:],
    rows: 24,
    cols: 80
  ))

  var iterator = manager.events.makeAsyncIterator()
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    guard let event = await iterator.next() else { break }
    if case .desktopNotification(let eventSession, let notification) = event {
      #expect(eventSession == session)
      #expect(notification.body == "Codex finished")
      manager.closeSession(session)
      return
    }
  }

  manager.closeSession(session)
  Issue.record("Expected desktop notification event")
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter ptySessionManagerEmitsDesktopNotificationEventForOsc9 --no-parallel
```

Expected: build fails because `TerminalEvent.desktopNotification` does not exist.

- [ ] **Step 3: Add the new TerminalEvent case**

In `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`, extend `TerminalEvent`:

```swift
public enum TerminalEvent: Sendable {
  case sessionCreated(TerminalSessionID)
  case sessionClosed(TerminalSessionID)
  case output(session: TerminalSessionID, data: Data)
  case osc(session: TerminalSessionID, sequence: OscSequence)
  case desktopNotification(session: TerminalSessionID, notification: TerminalDesktopNotification)
  case cwdChanged(session: TerminalSessionID, cwd: String)
  case titleChanged(session: TerminalSessionID, title: String)
  case error(session: TerminalSessionID, message: String)
}
```

- [ ] **Step 4: Emit the typed event in PTY output handling**

In `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`, inside `handleOutput(_:session:)`, update the OSC loop:

```swift
for sequence in sequences {
  continuation.yield(.osc(session: id, sequence: sequence))
  if let notification = TerminalDesktopNotificationParser.parse(sequence) {
    continuation.yield(.desktopNotification(session: id, notification: notification))
  }
  if let cwd = CwdTracker.cwd(from: sequence) {
    state.config.workingDirectory = cwd
    sessions[id] = state
    continuation.yield(.cwdChanged(session: id, cwd: cwd))
  }
  if sequence.command == "0" || sequence.command == "1" || sequence.command == "2",
    let title = sequence.parameters.last
  {
    continuation.yield(.titleChanged(session: id, title: title))
  }
}
```

- [ ] **Step 5: Verify the event test passes**

Run:

```bash
swift test --filter ptySessionManagerEmitsDesktopNotificationEventForOsc9 --no-parallel
```

Expected: the event test passes.

---

### Task 3: Add Notification Settings With Legacy-Safe Defaults

**Files:**
- Modify: `Sources/ProGhosttyCore/Settings/AppSettings.swift`
- Test: `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`

- [ ] **Step 1: Add settings tests**

Append to `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`:

```swift
@Test func decodesLegacySettingsWithNotificationDefaults() throws {
  let data = Data(#"{"themeName":"dark"}"#.utf8)

  let settings = try JSONDecoder().decode(AppSettings.self, from: data)

  #expect(settings.desktopNotificationsEnabled)
  #expect(settings.notifyOnCommandFinish == .unfocused)
  #expect(settings.notifyOnCommandFinishAfterSeconds == 5)
  #expect(settings.notifyOnCommandFinishBellEnabled)
  #expect(!settings.notifyOnCommandFinishDesktopEnabled)
}

@Test func notificationSettingsRoundTripThroughJSON() throws {
  var settings = AppSettings.defaults
  settings.desktopNotificationsEnabled = false
  settings.notifyOnCommandFinish = .always
  settings.notifyOnCommandFinishAfterSeconds = 12
  settings.notifyOnCommandFinishBellEnabled = false
  settings.notifyOnCommandFinishDesktopEnabled = true

  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

  #expect(decoded.desktopNotificationsEnabled == false)
  #expect(decoded.notifyOnCommandFinish == .always)
  #expect(decoded.notifyOnCommandFinishAfterSeconds == 12)
  #expect(decoded.notifyOnCommandFinishBellEnabled == false)
  #expect(decoded.notifyOnCommandFinishDesktopEnabled == true)
}
```

- [ ] **Step 2: Run the failing settings tests**

Run:

```bash
swift test --filter AppSettings --no-parallel
```

Expected: build fails because the new settings fields and enum do not exist.

- [ ] **Step 3: Add settings fields and enum**

In `Sources/ProGhosttyCore/Settings/AppSettings.swift`, add:

```swift
public enum TerminalCommandFinishNotificationPolicy: String, Codable, Equatable, Sendable {
  case never
  case unfocused
  case always
}
```

Add these stored properties to `AppSettings`:

```swift
public var desktopNotificationsEnabled: Bool
public var notifyOnCommandFinish: TerminalCommandFinishNotificationPolicy
public var notifyOnCommandFinishAfterSeconds: Double
public var notifyOnCommandFinishBellEnabled: Bool
public var notifyOnCommandFinishDesktopEnabled: Bool
```

Update `defaults`:

```swift
desktopNotificationsEnabled: true,
notifyOnCommandFinish: .unfocused,
notifyOnCommandFinishAfterSeconds: 5,
notifyOnCommandFinishBellEnabled: true,
notifyOnCommandFinishDesktopEnabled: false,
```

Update `CodingKeys`, the public initializer, and `init(from:)`. In `init(from:)`, use:

```swift
desktopNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopNotificationsEnabled) ?? Self.defaults.desktopNotificationsEnabled
notifyOnCommandFinish = try container.decodeIfPresent(TerminalCommandFinishNotificationPolicy.self, forKey: .notifyOnCommandFinish) ?? Self.defaults.notifyOnCommandFinish
notifyOnCommandFinishAfterSeconds = try container.decodeIfPresent(Double.self, forKey: .notifyOnCommandFinishAfterSeconds) ?? Self.defaults.notifyOnCommandFinishAfterSeconds
notifyOnCommandFinishBellEnabled = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCommandFinishBellEnabled) ?? Self.defaults.notifyOnCommandFinishBellEnabled
notifyOnCommandFinishDesktopEnabled = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCommandFinishDesktopEnabled) ?? Self.defaults.notifyOnCommandFinishDesktopEnabled
```

- [ ] **Step 4: Verify settings tests pass**

Run:

```bash
swift test --filter AppSettings --no-parallel
```

Expected: settings tests pass.

---

### Task 4: Send macOS Notifications With Rate Limiting

**Files:**
- Create: `Sources/ProGhosttyApp/TerminalNotificationCenter.swift`
- Test: `Tests/ProGhosttyAppTests/TerminalNotificationCenterTests.swift`

- [ ] **Step 1: Write notification center tests**

Create `Tests/ProGhosttyAppTests/TerminalNotificationCenterTests.swift`:

```swift
import Testing

@testable import ProGhostty
import ProGhosttyCore

@Suite("Terminal notification center")
struct TerminalNotificationCenterTests {
  @MainActor
  @Test func rateLimitsRepeatedDesktopNotifications() {
    let sender = RecordingTerminalNotificationSender()
    let center = TerminalNotificationCenter(sender: sender, minimumInterval: 1)
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    center.showDesktopNotification(notification, session: TerminalSessionID(), now: Date(timeIntervalSince1970: 10))
    center.showDesktopNotification(notification, session: TerminalSessionID(), now: Date(timeIntervalSince1970: 10.2))

    #expect(sender.requests.count == 1)
  }

  @MainActor
  @Test func allowsDifferentNotificationsWithinRateLimitWindow() {
    let sender = RecordingTerminalNotificationSender()
    let center = TerminalNotificationCenter(sender: sender, minimumInterval: 1)

    center.showDesktopNotification(
      TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777),
      session: TerminalSessionID(),
      now: Date(timeIntervalSince1970: 10)
    )
    center.showDesktopNotification(
      TerminalDesktopNotification(title: "Claude", body: "Waiting", source: .osc777),
      session: TerminalSessionID(),
      now: Date(timeIntervalSince1970: 10.2)
    )

    #expect(sender.requests.count == 2)
  }
}

@MainActor
private final class RecordingTerminalNotificationSender: TerminalNotificationSending {
  var requests: [(title: String, body: String)] = []

  func requestAuthorizationIfNeeded() {}

  func send(title: String, body: String) {
    requests.append((title, body))
  }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
swift test --filter TerminalNotificationCenterTests --no-parallel
```

Expected: build fails because `TerminalNotificationCenter` and `TerminalNotificationSending` do not exist.

- [ ] **Step 3: Add the app notification center**

Create `Sources/ProGhosttyApp/TerminalNotificationCenter.swift`:

```swift
import Foundation
import ProGhosttyCore
import UserNotifications

@MainActor
protocol TerminalNotificationSending: AnyObject {
  func requestAuthorizationIfNeeded()
  func send(title: String, body: String)
}

@MainActor
final class TerminalNotificationCenter {
  private let sender: TerminalNotificationSending
  private let minimumInterval: TimeInterval
  private var lastSentAtByFingerprint: [String: Date] = [:]

  init(
    sender: TerminalNotificationSending = MacTerminalNotificationSender(),
    minimumInterval: TimeInterval = 1
  ) {
    self.sender = sender
    self.minimumInterval = minimumInterval
  }

  func showDesktopNotification(
    _ notification: TerminalDesktopNotification,
    session: TerminalSessionID,
    now: Date = Date()
  ) {
    let fingerprint = "\(notification.title)\u{1F}\(notification.body)"
    if let last = lastSentAtByFingerprint[fingerprint],
      now.timeIntervalSince(last) < minimumInterval
    {
      return
    }
    lastSentAtByFingerprint[fingerprint] = now
    sender.requestAuthorizationIfNeeded()
    sender.send(title: notification.title, body: notification.body)
  }
}

@MainActor
private final class MacTerminalNotificationSender: TerminalNotificationSending {
  private var hasRequestedAuthorization = false

  func requestAuthorizationIfNeeded() {
    guard !hasRequestedAuthorization else { return }
    hasRequestedAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func send(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "proghostty.terminal.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}
```

- [ ] **Step 4: Verify notification center tests pass**

Run:

```bash
swift test --filter TerminalNotificationCenterTests --no-parallel
```

Expected: notification center tests pass.

---

### Task 5: Wire Desktop Notifications Into AppModel

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`
- Test: `Tests/ProGhosttyAppTests/TerminalNotificationCenterTests.swift`

- [ ] **Step 1: Add an AppModel handling test**

Append to `TerminalNotificationCenterTests.swift`:

```swift
@MainActor
@Test func appModelForwardsDesktopNotificationEventsWhenEnabled() {
  let sender = RecordingTerminalNotificationSender()
  let notificationCenter = TerminalNotificationCenter(sender: sender)
  let model = AppModel(terminalNotificationCenter: notificationCenter)
  let session = TerminalSessionID()

  model.handleForTesting(.desktopNotification(
    session: session,
    notification: TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)
  ))

  #expect(sender.requests.count == 1)
  #expect(sender.requests.first?.title == "Codex")
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter appModelForwardsDesktopNotificationEventsWhenEnabled --no-parallel
```

Expected: build fails because `AppModel` does not accept a notification center and `handleForTesting` does not exist.

- [ ] **Step 3: Inject notification center into AppModel**

In `Sources/ProGhosttyApp/UI/AppModel.swift`, add:

```swift
private let terminalNotificationCenter: TerminalNotificationCenter
```

Change the initializer:

```swift
init(terminalNotificationCenter: TerminalNotificationCenter = TerminalNotificationCenter()) {
  self.terminalNotificationCenter = terminalNotificationCenter
  DebugLog.write("AppModel init")
  ...
}
```

In `handle(_:)`, add:

```swift
case .desktopNotification(let session, let notification):
  guard settings.desktopNotificationsEnabled else { return }
  terminalNotificationCenter.showDesktopNotification(notification, session: session)
```

Add a test-only forwarding method near `handle(_:)`:

```swift
#if DEBUG
func handleForTesting(_ event: TerminalEvent) {
  handle(event)
}
#endif
```

- [ ] **Step 4: Verify AppModel notification test passes**

Run:

```bash
swift test --filter appModelForwardsDesktopNotificationEventsWhenEnabled --no-parallel
```

Expected: the test passes.

---

### Task 6: Track OSC 133 Command Lifecycle

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalCommandLifecycle.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalNotificationParserTests.swift`

- [ ] **Step 1: Add command lifecycle parser tests**

Append to `TerminalNotificationParserTests.swift`:

```swift
@Test func parsesOsc133CommandLifecycleMarkers() {
  #expect(TerminalCommandLifecycleParser.parse(
    OscSequence(raw: "133;C", command: "133", parameters: ["C"])
  ) == .started)

  #expect(TerminalCommandLifecycleParser.parse(
    OscSequence(raw: "133;D;0", command: "133", parameters: ["D", "0"])
  ) == .finished(exitCode: 0))

  #expect(TerminalCommandLifecycleParser.parse(
    OscSequence(raw: "133;D;2", command: "133", parameters: ["D", "2"])
  ) == .finished(exitCode: 2))

  #expect(TerminalCommandLifecycleParser.parse(
    OscSequence(raw: "133;A;cl=line", command: "133", parameters: ["A", "cl=line"])
  ) == .promptStarted)
}
```

- [ ] **Step 2: Run the failing parser test**

Run:

```bash
swift test --filter parsesOsc133CommandLifecycleMarkers --no-parallel
```

Expected: build fails because command lifecycle types do not exist.

- [ ] **Step 3: Add command lifecycle types**

Create `Sources/ProGhosttyCore/TerminalCore/TerminalCommandLifecycle.swift`:

```swift
import Foundation

public enum TerminalCommandLifecycleMarker: Equatable, Sendable {
  case started
  case finished(exitCode: Int?)
  case promptStarted
}

public struct TerminalCommandFinished: Equatable, Sendable {
  public var exitCode: Int?
  public var duration: TimeInterval

  public init(exitCode: Int?, duration: TimeInterval) {
    self.exitCode = exitCode
    self.duration = duration
  }
}

public enum TerminalCommandLifecycleParser {
  public static func parse(_ sequence: OscSequence) -> TerminalCommandLifecycleMarker? {
    guard sequence.command == "133", let marker = sequence.parameters.first else {
      return nil
    }
    switch marker {
    case "C":
      return .started
    case "D":
      let exitCode = sequence.parameters.dropFirst().first.flatMap(Int.init)
      return .finished(exitCode: exitCode)
    case "A":
      return .promptStarted
    default:
      return nil
    }
  }
}
```

- [ ] **Step 4: Add command-finished event state in PTY manager**

In `TerminalEvent`, add:

```swift
case commandFinished(session: TerminalSessionID, command: TerminalCommandFinished)
```

In `PTYTerminalSessionManager.SessionState`, add:

```swift
var commandStartedAt: Date?
```

Initialize it to `nil` where `SessionState` is created.

In the `handleOutput(_:session:)` OSC loop, after desktop notification parsing:

```swift
if let marker = TerminalCommandLifecycleParser.parse(sequence) {
  switch marker {
  case .started:
    state.commandStartedAt = Date()
    sessions[id] = state
  case .finished(let exitCode):
    if let startedAt = state.commandStartedAt {
      let finished = TerminalCommandFinished(
        exitCode: exitCode,
        duration: Date().timeIntervalSince(startedAt)
      )
      state.commandStartedAt = nil
      sessions[id] = state
      continuation.yield(.commandFinished(session: id, command: finished))
    }
  case .promptStarted:
    break
  }
}
```

- [ ] **Step 5: Add and run a PTY manager command-finished test**

Append:

```swift
@MainActor
@Test func ptySessionManagerEmitsCommandFinishedEventForOsc133() async throws {
  let registry = PTYTerminalSurfaceRegistry()
  let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
  let session = try manager.createSession(config: TerminalSessionConfig(
    shellPath: "/bin/zsh",
    launchCommand: "printf '\\033]133;C\\007'; sleep 0.05; printf '\\033]133;D;0\\007'",
    workingDirectory: nil,
    environment: [:],
    rows: 24,
    cols: 80
  ))

  var iterator = manager.events.makeAsyncIterator()
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    guard let event = await iterator.next() else { break }
    if case .commandFinished(let eventSession, let command) = event {
      #expect(eventSession == session)
      #expect(command.exitCode == 0)
      #expect(command.duration >= 0.04)
      manager.closeSession(session)
      return
    }
  }

  manager.closeSession(session)
  Issue.record("Expected command finished event")
}
```

Run:

```bash
swift test --filter ptySessionManagerEmitsCommandFinishedEventForOsc133 --no-parallel
```

Expected: the event test passes.

---

### Task 7: Apply Ghostty-Like Command Finish Policy

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`
- Test: `Tests/ProGhosttyAppTests/TerminalNotificationCenterTests.swift`

- [ ] **Step 1: Add policy tests**

Append to `TerminalNotificationCenterTests.swift`:

```swift
@MainActor
@Test func appModelDoesNotNotifyShortCommandFinish() {
  let sender = RecordingTerminalNotificationSender()
  let model = AppModel(terminalNotificationCenter: TerminalNotificationCenter(sender: sender))
  model.settings.notifyOnCommandFinish = .always
  model.settings.notifyOnCommandFinishDesktopEnabled = true
  model.settings.notifyOnCommandFinishAfterSeconds = 5

  model.handleForTesting(.commandFinished(
    session: TerminalSessionID(),
    command: TerminalCommandFinished(exitCode: 0, duration: 1)
  ))

  #expect(sender.requests.isEmpty)
}

@MainActor
@Test func appModelNotifiesLongCommandFinishWhenDesktopActionEnabled() {
  let sender = RecordingTerminalNotificationSender()
  let model = AppModel(terminalNotificationCenter: TerminalNotificationCenter(sender: sender))
  model.settings.notifyOnCommandFinish = .always
  model.settings.notifyOnCommandFinishDesktopEnabled = true
  model.settings.notifyOnCommandFinishAfterSeconds = 5

  model.handleForTesting(.commandFinished(
    session: TerminalSessionID(),
    command: TerminalCommandFinished(exitCode: 0, duration: 6)
  ))

  #expect(sender.requests.count == 1)
  #expect(sender.requests.first?.title == "Command Succeeded")
}
```

- [ ] **Step 2: Run the failing policy tests**

Run:

```bash
swift test --filter appModelNotifiesLongCommandFinishWhenDesktopActionEnabled --no-parallel
```

Expected: test fails because `AppModel` does not handle `.commandFinished`.

- [ ] **Step 3: Implement command finish policy**

In `AppModel.handle(_:)`, add:

```swift
case .commandFinished(let session, let command):
  handleCommandFinished(session: session, command: command)
```

Add:

```swift
private func handleCommandFinished(session: TerminalSessionID, command: TerminalCommandFinished) {
  guard command.duration >= settings.notifyOnCommandFinishAfterSeconds else { return }
  switch settings.notifyOnCommandFinish {
  case .never:
    return
  case .unfocused:
    if selectedSessionID == session && NSApp.isActive { return }
  case .always:
    break
  }

  if settings.notifyOnCommandFinishBellEnabled {
    NSSound.beep()
  }

  guard settings.desktopNotificationsEnabled, settings.notifyOnCommandFinishDesktopEnabled else {
    return
  }

  let title: String
  if let exitCode = command.exitCode {
    title = exitCode == 0 ? "Command Succeeded" : "Command Failed"
  } else {
    title = "Command Finished"
  }

  let body: String
  if let exitCode = command.exitCode, exitCode != 0 {
    body = "Command took \(Self.formattedDuration(command.duration)) and exited with code \(exitCode)."
  } else {
    body = "Command took \(Self.formattedDuration(command.duration))."
  }

  terminalNotificationCenter.showDesktopNotification(
    TerminalDesktopNotification(title: title, body: body, source: .osc777),
    session: session
  )
}

private static func formattedDuration(_ duration: TimeInterval) -> String {
  if duration >= 60 {
    return "\(Int(duration / 60))m \(Int(duration) % 60)s"
  }
  return "\(Int(duration))s"
}
```

- [ ] **Step 4: Verify command finish policy tests pass**

Run:

```bash
swift test --filter TerminalNotificationCenterTests --no-parallel
```

Expected: app notification tests pass.

---

### Task 8: Add Settings UI Copy and Controls

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Modify: `Sources/ProGhosttyApp/UI/SettingsView.swift`

- [ ] **Step 1: Add localized text keys**

In `AppText`, add:

```swift
var notifications: String { text("Notifications", "通知") }
var desktopNotifications: String { text("Desktop notifications", "系统通知") }
var commandFinishNotifications: String { text("Command finish notifications", "命令完成通知") }
var notifyNever: String { text("Never", "从不") }
var notifyWhenUnfocused: String { text("When unfocused", "未聚焦时") }
var notifyAlways: String { text("Always", "始终") }
var notifyAfterSeconds: String { text("Notify after seconds", "超过秒数后通知") }
var notifyWithBell: String { text("Bell", "响铃") }
var notifyWithDesktop: String { text("Desktop", "系统通知") }
```

- [ ] **Step 2: Add controls in SettingsView**

Add a compact notifications section near renderer or general settings:

```swift
Section(text.notifications) {
  Toggle(text.desktopNotifications, isOn: $model.settings.desktopNotificationsEnabled)

  Picker(text.commandFinishNotifications, selection: $model.settings.notifyOnCommandFinish) {
    Text(text.notifyNever).tag(TerminalCommandFinishNotificationPolicy.never)
    Text(text.notifyWhenUnfocused).tag(TerminalCommandFinishNotificationPolicy.unfocused)
    Text(text.notifyAlways).tag(TerminalCommandFinishNotificationPolicy.always)
  }

  HStack {
    Text(text.notifyAfterSeconds)
    TextField("", value: $model.settings.notifyOnCommandFinishAfterSeconds, format: .number)
      .frame(width: 72)
  }

  Toggle(text.notifyWithBell, isOn: $model.settings.notifyOnCommandFinishBellEnabled)
  Toggle(text.notifyWithDesktop, isOn: $model.settings.notifyOnCommandFinishDesktopEnabled)
}
```

If the existing `SettingsView` does not use `Section`, adapt this to its current form-row pattern and keep the labels above.

- [ ] **Step 3: Build to verify UI compiles**

Run:

```bash
swift build
```

Expected: build succeeds.

---

### Task 9: Manual Verification

**Files:**
- No code changes.

- [ ] **Step 1: Run full tests**

Run:

```bash
swift test --no-parallel
```

Expected: all tests pass.

- [ ] **Step 2: Build and launch app**

Run:

```bash
swift build
scripts/build-app-bundle.sh debug
open .build/arm64-apple-macosx/debug/ProGhostty.app
```

Expected: app launches.

- [ ] **Step 3: Verify OSC 9 notification**

In ProGhostty, run:

```zsh
printf '\e]9;Codex finished and is waiting for input\a'
```

Expected: macOS notification appears with body `Codex finished and is waiting for input`.

- [ ] **Step 4: Verify OSC 777 notification**

In ProGhostty, run:

```zsh
printf '\e]777;notify;Codex;Waiting for input\a'
```

Expected: macOS notification appears with title `Codex` and body `Waiting for input`.

- [ ] **Step 5: Verify command finish notification**

Enable desktop action for command finish in settings, then run:

```zsh
sleep 6
```

Expected: after the command returns, ProGhostty triggers the configured bell/desktop action if the policy allows it.

- [ ] **Step 6: Verify terminal BEL notification**

In ProGhostty, put the app in the background or set terminal bell notifications
to `Always`, then run:

```zsh
printf '\a'
```

Expected: ProGhostty triggers the configured terminal bell desktop notification.

- [ ] **Step 7: Verify OSC terminator BEL does not double notify**

Run:

```zsh
printf '\e]777;notify;Codex;Waiting for input\a'
```

Expected: one desktop notification appears for the OSC notification. There
should not be a second generic terminal bell notification.

- [ ] **Step 8: Verify no rendered-text dependency**

Run a command that prints notification-like text without OSC:

```zsh
echo "Codex finished and is waiting for input"
```

Expected: no notification is triggered.

---

## Codex Hook Verification

The project-local Codex `Stop` hook emits:

```zsh
printf '\e]777;notify;Codex;Waiting for input\a' >/dev/tty
```

and returns this JSON on stdout:

```json
{"continue":true}
```

The repo-local hook config must use Codex's official top-level `hooks` shape:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/bin/sh \"$(git rev-parse --show-toplevel)/.codex/hooks/proghostty_codex_stop_notify.sh\""
          }
        ]
      }
    ]
  }
}
```

Manual verification:

1. Open this repository in ProGhostty.
2. Run `/hooks` in interactive Codex and trust the repo-local `Stop` hook if it is listed for review.
3. Run a short Codex task.
4. When Codex finishes the turn and waits for input, ProGhostty should receive the OSC 777 notification and show the configured desktop notification.

Equivalent script verification without a live Codex run:

```zsh
tmp="$(mktemp)"
TERM_PROGRAM=ProGhostty PROGHOSTTY_NOTIFY_TTY="$tmp" .codex/hooks/proghostty_codex_stop_notify.sh
xxd -p "$tmp"
```

Expected stdout is `{"continue":true}` and the temporary file contains:

```text
1b5d3737373b6e6f746966793b436f6465783b57616974696e6720666f72
20696e70757407
```

Current verification evidence:

- `python3 -m json.tool .codex/hooks.json` passes.
- `.codex/hooks/proghostty_codex_stop_notify.sh` is executable.
- Script-level verification writes the expected OSC 777 bytes to the target TTY path.
- `codex exec --dangerously-bypass-hook-trust` does not trigger repo-local hooks on this machine; do not use it as the final acceptance test.
- Interactive Codex `/hooks` shows `Stop` as `Installed 1` and `Active 1` after trusting the repo-local hook.
- A temporary diagnostic marker proved the interactive Codex `Stop` hook runs when a turn finishes and Codex returns to waiting input.
- Codex hook subprocesses did not inherit `PROGHOSTTY_NOTIFY_TTY`, so automated file capture does not prove or disprove `/dev/tty` output. The final script writes to `/dev/tty` by default.
- `swift test --no-parallel` passes with 524 tests.
- `swift build` passes.
- `scripts/build-app-bundle.sh debug` passes.
- `git diff -- Sources/ProGhosttyCore/TerminalCore/Renderer Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift` is empty.

## Claude Code Follow-Up

Claude Code has its own hooks and plugin model. The same architecture should be
used there: tool-side hook writes `OSC 777` to `/dev/tty`, ProGhostty receives it
as a normal terminal notification event. Do not infer Claude's waiting-input
state by scanning rendered text.

If a wrapper or native hook cannot reliably detect an agent waiting-input state,
define a ProGhostty private agent status OSC separately from `pg` control
commands, for example:

```text
OSC 777;proghostty-agent;{"app":"codex","state":"waiting_input","summary":"Task complete"}
```

That protocol should be parsed as a safe status event only. It must not execute commands or reuse the existing privileged `ProGhosttyControlOscParser` authorization path.

## Self-Review

- Spec coverage: Covers Ghostty-style OSC 9, OSC 777, OSC 133 command finish, app policy, settings, macOS notification delivery, and manual verification.
- Placeholder scan: No deferred implementation placeholders remain in the task steps.
- Type consistency: `TerminalDesktopNotification`, `TerminalCommandFinished`, `TerminalEvent.desktopNotification`, `TerminalEvent.commandFinished`, and `TerminalEvent.bell` are used consistently.
- Scope check: Codex waiting-input notification is handled by a project-local `Stop` hook; final visual acceptance still requires checking the macOS notification appears in ProGhostty with notification permission enabled. Claude Code integration remains a follow-up unless requested.
