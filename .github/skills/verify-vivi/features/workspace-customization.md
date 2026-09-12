# Workspace customization

Vivi loads Copilot instruction files for the active workspace and exposes
user-invocable project skills in the slash-command menu.

## Sub-features

- A top-level `AGENTS.md` contributes instructions to the conversation.
- Skills are discovered from `.github/skills/`, `.agents/skills/`, and
  `.claude/skills/`.
- Skills marked `user-invocable: true` appear in the `/` menu with their
  descriptions.
- Selecting a skill submits Copilot's expanded skill prompt and streams the
  response as a normal turn.

## How to get to it (user POV)

Start `vivi chat` inside a workspace containing `AGENTS.md` or project skills.
Type `/` to browse user-invocable skills, filter by skill name, and press Enter
to invoke the selected skill.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-customization <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-customization
```

The recipe creates an isolated workspace with a deterministic `AGENTS.md` and
`.agents/skills/vivi-fixture/SKILL.md`. It verifies the instruction response,
without naming the expected token in the user prompt, the skill row in the
slash menu, and the response produced by invoking it.

## Gotchas

- A skill must declare `user-invocable: true` to appear in the slash menu.
- Instruction and skill discovery follow Copilot CLI semantics; Vivi does not
  parse or reinterpret those files.
- Vivi passes only the workspace root as an instruction source and the three
  documented skill roots; it does not enable ambient workspace configuration
  discovery or workspace-configured MCP servers.
- The recipe needs authenticated Copilot access because both assertions cross
  the production SDK boundary.
