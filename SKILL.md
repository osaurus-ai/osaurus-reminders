---
name: osaurus-reminders
description: Use when listing, finding, creating, or opening reminders in macOS Reminders.
---

# Reminders

- Call `list_reminder_lists` before a list-scoped query or creation when no stable list ID is already available. Never substitute a list title for `list_id`.
- Use `query_reminders` for both browsing and text search. Omit `query` to browse; inspect `has_more` before treating a bounded result as exhaustive.
- Before `create_reminder`, resolve relative dates to an absolute RFC3339 date-time with the user's timezone. Omit `list_id` only when the default list is intended.
- Creation and opening require approval. Use the returned reminder `id` with `open_reminder`; do not guess an ID or report the app as opened when the tool fails.
- Treat `is_writable: false` as authoritative and choose another list before attempting creation.
