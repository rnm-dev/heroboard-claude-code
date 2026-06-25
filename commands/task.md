---
description: Show a Heroboard task's full details
argument-hint: "<ISSUE-KEY, e.g. HB-203>"
---
Call the heroboard MCP tool `get_task` with issueKey `$ARGUMENTS` and present the result clearly:
title, type, status, description, epic/release/assignee, value & estimate, attachment count,
then the comments and recent history. If the key is missing or not found, say so and suggest `/heroboard:tasks`.
