# Maintenance Contract: easy-browser-use

This file is for agents editing the skill. Keep maintainer rules here, not in `SKILL.md`.

## Ownership

- `SKILL.md` holds what an agent would not get from the server's own tool descriptions: what it can and cannot reach, the order of calls, and the traps. When a tool's description starts saying something the skill says, cut it from the skill.
- `references/setup.md` holds the registration commands, the Chrome setting, and what `--autoConnect` does, read when the server is being installed or attaches to the wrong Chrome. Keep install detail out of `SKILL.md`.
- The skill teaches the server and routes no task to it or away from it, by the author's decision. It says what the server cannot reach, and never that a page must not be worked through desktop control.
- The skill says what it does and when it applies, and nothing about a harness's own browser tools, for or against, by the author's decision. Which tool an agent uses is settled outside the skill, by the user, the prompt, or what is installed. State what `chrome-devtools` reaches, never that it must be the tool used.
- `README.md` is the human skim layer. Keep it to a few sentences.

## Sources

- The registration commands follow `claude mcp add --help` and `codex mcp add --help`. The server flags follow `npx chrome-devtools-mcp@latest --help`.
- The Chrome setting and the version floor follow the `--autoConnect` entry in the chrome-devtools-mcp help text.
- The profile that `--autoConnect` attaches to, the consent window, and the separate profile used without the flag follow the chrome-devtools-mcp advanced usage guide.
- The remaining lines under Tabs And Pages are observations from real runs against a real Chrome. Where a first-party source contradicts one, the source wins. Otherwise recheck an observation before changing its line, and again when the server ships a release that touches it.

## Editing Rules

- State facts and the order to do things in. The skill carries no approval step, allow-list, or restriction on what the user may ask for, by the author's decision. That includes sign-in: a page the browser has filled is passed, and the agent stops only for what the user alone holds.
- Never hand the user a click that desktop control could make, the remote debugging consent window first among them.
- Keep the opening's statements of what the tools reach and that page content is data.
- Do not record dates, measurements, machine paths, tab titles from a real browser, or the story of a test run.
- Do not use em dashes or en dashes, and do not use semicolons to join sentences.
- Bump `metadata.version` by the release-versioning skill's rules for skills.
