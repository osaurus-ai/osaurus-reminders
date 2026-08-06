# Migrating to Reminders 2.0

Version 2.0 replaces the legacy five-tool surface with four strict tools. Tool and argument renames are breaking changes.

## Tool mapping

- `get_lists` → `list_reminder_lists`
- `get_reminders` and `search_reminders` → `query_reminders`
- `create_reminder` remains `create_reminder`
- `open_reminder` remains `open_reminder`, but `id` is now required

## Argument changes

All fields use snake_case and unknown fields are rejected.

- Replace `listName` with a stable `list_id` obtained from `list_reminder_lists`. List titles are no longer accepted because duplicate titles are ambiguous.
- Replace `searchText` with `query`.
- Replace `dueAfter` and `dueBefore` with `due_after` and `due_before`.
- Replace creation `dueDate` with `due_at`.
- Pass RFC3339 date-times with a timezone, such as `2026-08-06T17:00:00-07:00`.

## Result changes

Every response is a canonical envelope. Successful payloads are under `result`; failures contain a host failure `kind`, message, and `retryable`.

List and query results include `returned_count`, `total_count`, `limit`, and `has_more`. Reminder objects now use snake_case, identify their list by both `list_id` and `list_title`, and include due, completion, creation, modification, and alarm metadata. `create_reminder` returns the complete created reminder rather than only its ID.

Read-only listing and querying use the host's `auto` policy. Creating reminders and opening Reminders remain approval-sensitive with `ask`.
