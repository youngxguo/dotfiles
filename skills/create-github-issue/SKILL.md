---
name: create-github-issue
description: Format concise GitHub issue content as a bug report or feature request. Use when asked to write, format, structure, or improve a GitHub issue, bug report, or feature request.
---

# create github issue

Turn the supplied facts into a focused issue. Preserve the meaning, remove repetition, and do not invent missing details.

## bug

Use this format:

```markdown
fix(repo): <summary>

## what happened

<observed behavior>

## expected

<expected behavior>

## steps to reproduce

<steps>

## notes

<useful supporting details>
```

## feature

Use this format:

```markdown
feat(repo): <summary>

## idea

<desired change>

## why

<motivation or benefit>

## notes

<useful constraints or details>
```

## style

- Write a short, lowercase title without trailing punctuation.
- Replace `repo` with a supplied scope when it makes the title clearer.
- Keep one issue focused on one bug or feature.
- Use short paragraphs or bullets under each heading.
- Omit `notes` when there are no useful notes. Omit any other section only when the supplied content cannot support it.
- Return the title and body without extra commentary unless requested.
