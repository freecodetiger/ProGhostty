# Codex Command Capsule MVP Design

## Goal

Build the first stable version of ProGhostty's Codex-focused AI layer as a floating Command Capsule. The capsule helps the user turn voice or short text into a high-quality Codex prompt, optionally refines it through an OpenAI-compatible model, and sends the final draft to an existing or newly launched Codex CLI pane.

This first version optimizes Codex input. It does not try to replicate Codex's internal context, maintain long-running sidecar memory, or automate terminal control.

## Product Principles

- The terminal remains the primary surface. The capsule floats above the terminal and never resizes pane layout.
- Codex CLI remains the execution agent. ProGhostty only prepares and sends prompts through existing terminal input.
- Context is explicit and small. The user can see which context sources are included before sending.
- Actions are confirm-first. The default action pastes to Codex without pressing return; explicit "Send + Enter" executes.
- The UI feels like a terminal-native command tool, not a chat product.

## Non-Goals

- No persistent chat sidebar.
- No automatic observation of Codex output.
- No automatic prompt sending.
- No long-term memory per directory.
- No large file-content attachment by default.
- No dependency on Codex private protocols.

## User Flow

1. The user opens the capsule from the AI menu or a keyboard shortcut.
2. The capsule appears near the bottom center of the terminal window.
3. The user types a short request or starts voice recording.
4. Voice partial transcripts stream inside the capsule; final transcripts append to the request draft.
5. The user can refine the request using an OpenAI-compatible API.
6. The model returns a Codex-ready draft.
7. The user can edit the draft.
8. The user sends it to Codex using bracketed paste, with or without pressing return.

If no Codex session exists, the capsule can start one using the existing `AISessionManager` and then send the prompt.

## Visual Design

The capsule is a floating panel, not a side sheet.

- Placement: bottom center by default, inset from the terminal edge.
- Width: 560-720 px on desktop, capped by available window width.
- Height: compact in idle/listening states, expandable to a scrollable draft area after refine.
- Material: slightly elevated terminal-adjacent background, one-pixel separator, restrained shadow.
- Typography: system UI font for controls and labels, monospaced font for prompt preview.
- Color: neutral terminal-compatible colors, one accent color for recording and primary action.
- Motion: 120-180 ms entrance/exit; subtle recording pulse only while listening.

The capsule states are:

- `idle`: request field, microphone action, context chips, primary refine/send actions.
- `listening`: live transcript, stop/cancel actions, visible recording state.
- `refining`: disabled inputs, progress indicator, cancel action.
- `ready`: editable Codex draft, context summary, send actions.
- `error`: concise error with retry and dismiss.
- `sent`: short confirmation, then return to idle or dismiss.

The UI avoids chat bubbles, avatars, large gradients, and persistent message history.

## Architecture

The feature adds a small sidecar layer beside the existing AI CLI companion code.

```text
SwiftUI Command Capsule
  -> AppModel command capsule state
  -> CodexPromptRefiner
  -> OpenAICompatibleChatClient
  -> AIPromptContext / GitContextCollector / selected terminal text
  -> AISessionManager
  -> PTY terminal input
```

The existing `AliyunASRService` remains the speech source. The existing `AISessionManager` remains the terminal delivery mechanism.

## Components

### Command Capsule State

Add a focused state model for the floating capsule:

- visibility
- input request
- voice partial transcript
- generated Codex draft
- selected context options
- lifecycle state
- current error message

This state belongs at the app layer because it coordinates UI, ASR, OpenAI-compatible API calls, and terminal delivery.

### OpenAI-Compatible Settings

Add settings for:

- API base URL
- API key
- model name

The API key should follow the same pragmatic hierarchy as the existing ASR key:

1. keychain, if later added for this provider
2. app setting
3. environment variable

For the MVP, app setting plus environment fallback is acceptable. The settings UI must make clear that this key is used only for prompt refinement.

### OpenAI-Compatible Client

Add a small client for `/chat/completions` compatible APIs.

Input:

- system message defining the model's job as Codex prompt refinement
- user request
- selected context

Output:

- a single prompt string suitable for pasting into Codex

The client should support non-streaming first. Streaming is a later enhancement.

### Prompt Refinement

The refiner should produce a direct Codex instruction, not a conversational answer.

The generated prompt should include:

- task statement
- relevant explicit context
- constraints such as "keep changes small" and "verify with commands"
- a request to ask focused questions if information is insufficient

If the API is not configured or fails, the capsule should still allow sending the raw request to Codex.

### Context

MVP context options:

- workspace path
- git branch
- git status
- changed file list
- selected terminal text

Excluded from MVP:

- full git diff by default
- recent terminal output auto-capture
- file contents
- Codex output parsing
- long-term project memory

## Error Handling

- Missing ASR key: show a concise error and keep typed input usable.
- Microphone denied: show a concise permission error and keep typed input usable.
- Missing OpenAI-compatible key/model/base URL: skip refine and allow raw send.
- API request failure: show the error, preserve the user request, and offer retry.
- No active terminal pane: show an error and do not discard draft.
- No active Codex session: offer to start Codex before sending.

## Testing

Core tests should cover:

- OpenAI-compatible request encoding.
- OpenAI-compatible response decoding.
- Missing API configuration behavior.
- Prompt refiner input/output behavior.
- Command capsule reducer/state transitions.
- Sending a ready draft through `AISessionManager` using bracketed paste.

UI tests are not required for the MVP, but the SwiftUI state should be structured so the view is thin and testable through core logic.

## Implementation Scope

The stable first version is complete when:

- A floating command capsule can be opened and dismissed.
- The user can type a request.
- The user can record voice through Aliyun ASR and append final transcript to the request.
- The user can refine the request through an OpenAI-compatible API.
- The generated draft remains editable.
- The user can paste or paste-and-enter the draft into Codex CLI.
- Failure states preserve user input and provide a clear next action.
