---
description: Create a Heroboard task from a plain-English description
argument-hint: "<what to build, e.g. 'bug: login 500 on empty email in HB'>"
---
Create a Heroboard task from `$ARGUMENTS` using the heroboard MCP tool `create_task`.

1. **Project.** If the text names a project key (e.g. `HB`), use it. Otherwise call `list_projects`
   and pick the most relevant; if it's ambiguous, ask me before creating anything.
2. **Map the description to fields** — don't make me spell them out:
   - `title` — a concise imperative summary (min 3 chars). Strip the type/project prefix from it.
   - `type` — `bug`, `feature`, or `chore`. Infer from wording ("fix/broken/500" → bug,
     "add/support" → feature, "bump/cleanup/rename" → chore). Default to `feature` if unclear.
   - `description` — any extra detail beyond the title (optional; omit if there's nothing to add).
   - `epicName` — only if I clearly reference an epic; it's created if missing.
   - `status` — leave unset (lands in Backlog) unless I say where to put it
     (todo/inprogress/review/deploying/qa/resolved/released).
   - `estimateHours` — only if I give a number; this is planned human vibe-coding effort.
3. **Create it** with `create_task` and report the returned issue key, type, and status in one line.
   If I described several tasks, create each and list the keys.

Don't invent estimates, epics, or statuses I didn't ask for — keep the task clean.
