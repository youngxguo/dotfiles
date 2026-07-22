---
name: create-git-commit
description: Create a focused Git commit with a clear lowercase message that follows repository conventions. Use when asked to commit current changes, make a Git commit, checkpoint work, or turn worktree changes into a commit.
---

Create the requested commit without pushing unless explicitly requested.

Follow the repository's commit format. When none is defined, use one of these title forms:

```text
<emoji> <type>(<scope>): <summary>
<emoji> <type>: <summary>
```

Use these defaults:

- `📝 docs` for documentation
- `✨ feat` for new behavior
- `🐛 fix` for corrected behavior
- `♻️ refactor` for internal restructuring
- `🔧 chore` for maintenance
- `🎨 style` for formatting-only changes

- Write the title and body in lowercase, except where exact capitalization is required for names or identifiers.
- Use imperative style and omit trailing punctuation from the title.
- Keep the title short and specific, and include a scope only when it adds useful context.
- Add a body only when the reason, tradeoff, or important context is not clear from the title.
