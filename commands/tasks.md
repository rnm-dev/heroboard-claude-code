---
description: List your Heroboard tasks for a project
argument-hint: "[project key, e.g. HB]"
---
Using the heroboard MCP tools, show my tasks.

1. If `$ARGUMENTS` names a project key, use it; otherwise call `list_projects` and pick the most relevant (ask me if unsure).
2. Call `list_tasks` for that project.
3. Show the tasks grouped by status (To Do / In Progress / Code Review / QA / Done), with the issue key, title and type. Keep it compact.
