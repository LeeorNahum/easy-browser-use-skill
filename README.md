# easy-browser-use-skill

Agent Skill that tells an agent in any harness how to drive the user's real, signed-in Chrome through an existing MCP server, [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp). Its sibling, [easy-computer-use](https://github.com/LeeorNahum/easy-computer-use-skill), covers the Windows desktop.

On Windows it also ships a launcher to register in place of the plain server command, and a script that answers the browser's Save As and Open dialogs.

- `SKILL.md` and `references/`: what the server reaches, the order of calls, the traps, and setup
- `scripts/` and `package.json`: the launcher and its scripts
- `AGENTS.md`: rules for editing this skill
