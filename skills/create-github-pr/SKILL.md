---
name: create-github-pr
description: Open a focused, ready-for-review GitHub pull request with a concise lowercase title and body. Use when asked to create, open, submit, or publish a pull request or PR from the current repository.
---

Open the pull request ready for review. Create a draft only when explicitly requested.

Follow the repository's pull request template and title conventions. When none are defined, reuse or adapt the commit title when it accurately summarizes the entire pull request. Otherwise, follow the title format and writing rules from `$create-git-commit`.

Write a concise body:

```markdown
## summary

- <what changed and why>

## checks

- <validation performed>
```

Keep the summary to what changed and why. List only checks actually performed. Mention risks or follow-up work only when meaningful.
