# Privacy

Dynamic Peninsula runs on your Mac and uses your local applications, accounts, and files.

## Data access

| Feature | Data used |
| --- | --- |
| Music | Now Playing information and music-app controls |
| Codex | Local login credentials, account usage, and session statistics |
| Claude | A session key in macOS Keychain, account usage, and session statistics |
| AgentLight | Local session status files |
| Clipboard | Items copied to the system clipboard |
| Shelf and AirDrop | Files and links you select or drag into the app |
| System monitor | CPU, GPU, memory, storage, temperature, and fan readings |
| Calendar, camera, and HUD | The macOS permissions for each integration |

## Account requests

Account monitors start with the app and use credentials saved on the Mac:

- **Codex** reads `~/.codex/auth.json` and queries usage and credits at `chatgpt.com`. Expired access tokens are refreshed through `auth.openai.com`. Refreshed tokens stay in process memory.
- **Claude** reads the saved session key from macOS Keychain and queries organization and usage information at `claude.ai`.

Authentication information goes directly to the corresponding service.

Opening the Codex or Claude tab reads `~/.codex/sessions` or `~/.claude/projects` to calculate session statistics. AgentLight reads `~/.agentlight` and updates stale running states to idle. Download progress uses the Downloads folder.

## Local storage

Preferences, permissions, clipboard history, and Shelf items are stored locally. Preferences and saved items persist after the app is removed.

## Contact

Report privacy issues with a redacted reproduction in [Issues](https://github.com/zhn66776/dynamic-peninsula/issues).
