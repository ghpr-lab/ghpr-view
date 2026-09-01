# ghpr Skill Builder

Create, migrate, or enhance ghpr Skills against the contracts exported by the installed ghpr version.

## Required first step

Run:

```bash
ghpr contract capabilities --json
ghpr contract export --version latest --json
```

Treat those results as authoritative. Do not rely on copied contract fields from this file. Stop if the requested target, agent, presentation section, Browser slot, or capability is unavailable.

## Select one mode

### Create

Use when the user wants a new Skill.

1. Clarify the observable trigger, input context, result, presentation, and optional GitHub-page placement.
2. Run `ghpr skill scaffold --id <id> --name <name> --directory <parent>`.
3. Edit the generated package: `ghpr.skill.yaml`, `SKILL.md`, result schema, presentation, Browser contributions, and fixtures.
4. Run the complete verification flow below.

### Migrate

Use when adapting an existing Claude Code, Codex, or OMP Skill.

1. Preserve the original Skill unchanged.
2. Create a ghpr-managed package and copy the original under `legacy/`.
3. Infer explicit inputs and structured output. If that is unsafe, retain Level 0 output only: `status`, `output`, `artifacts`, and `logs`.
4. Add presentation, menu contribution, and fixture coverage without changing the original logic.
5. Run the complete verification flow below.

### Enhance

Use when adding presentation, Browser contributions, fixtures, or another Skill action to an existing ghpr package.

1. Keep execution instructions and result semantics unchanged unless the user explicitly requests them.
2. Modify only `presentation/`, `browser/`, and the fixtures required by the new observable contract.
3. Run the complete verification flow below.

## Default safety contract

Every new package starts with:

```yaml
execution:
  isolation: strict
workspace:
  checkout: none
  cwd: run_root
  access: read_only
  shell: denied
network:
  access: denied
automation:
  enabled: false
tags:
  auto_apply: false
browser:
  requested_scopes:
    - pr:read
    - ci:read
    - analysis:read
    - ui:contribute
```

Upgrade a capability only when the user explicitly requires it. Before installation, show a permission diff for writable worktrees, test execution, network access, automatic execution, automatic tags, GitHub writes, artifact reads, or a companion userscript.

Never request or expose GitHub tokens, workspace paths, raw repository reads, agent credentials, or shell execution from Browser clients.

## Verification flow

Run all stages in order:

```bash
ghpr skill validate <package>
ghpr skill test <package>
ghpr skill preview <package>
ghpr skill pack <package> --output <artifact>
```

Review:

- Native summary and detail presentation.
- Context-menu placement.
- GitHub semantic-slot preview and fallback behavior.
- Event-rule simulation when automation is declared.
- Permission diff.
- Raw result JSON against the package schema.

Install only after validation and fixture testing pass:

```bash
ghpr skill install <package>
```

Do not leave placeholders, disabled validation, missing fixtures, or undocumented elevated permissions.
