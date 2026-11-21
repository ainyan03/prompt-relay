# Screen fixtures

Captured terminal screens used by the hook tests to check approval prompt
detection and fingerprinting.

- Keep these as real captures from Claude Code / Codex / Antigravity CLI running in tmux, herdr, or cmux,
  not hand-written screens. Hand-written screens have missed real layouts
  before, such as the labeled separator line that tmux shows below the
  approval footer, and the agent wrapping its own prompt text (sometimes in the
  middle of a word) at a different column when the terminal width changes.
- When you change `prompt_parser.py`, run the tests against these fixtures. If
  the change concerns a layout that no fixture covers, capture that screen from
  a real session and add it here first.
- Remove anything private from a capture before adding it (home directory
  paths, user names, host names, tokens).

The herdr fixtures retain only the approval region of captured screens. The
`hc` suffix denotes the app's terminal transport; `herdr` denotes the TUI.
