# osaurus-reminders

An Osaurus plugin for reading and writing macOS Reminders through EventKit and opening a selected reminder through bounded AppleScript automation.

## Permissions

The host application needs:

- **Reminders full access** for all tools. Enable it in System Settings → Privacy & Security → Reminders. The host must provide `NSRemindersFullAccessUsageDescription` on macOS 14+ (or `NSRemindersUsageDescription` on older systems).
- **Automation access to Reminders** for `open_reminder`. Enable it in System Settings → Privacy & Security → Automation. The host must provide `NSAppleEventsUsageDescription`.

Read-only listing and querying use the host's `auto` policy. Creating a reminder or activating Reminders uses `ask`.

## Tools

### `list_reminder_lists`

Returns a bounded list of reminder lists with stable IDs, color, account ID/name/type, writability, and default-list metadata.

```json
{}
```

### `query_reminders`

Browses and searches reminders in one tool. Filters include:

- `query`: optional title/notes text
- `list_id`: optional stable ID from `list_reminder_lists`
- `status`: `incomplete` (default), `completed`, or `all`
- `due_after` / `due_before`: inclusive RFC3339 date-times
- `limit`: 1–200 (default 50)

```json
{
  "query": "project deadline",
  "list_id": "stable-list-id",
  "status": "all",
  "due_before": "2026-08-31T23:59:59-07:00",
  "limit": 25
}
```

### `create_reminder`

Creates a reminder in the default list or the writable list selected by `list_id`. `title` is required. Optional fields are `notes`, `list_id`, `due_at`, and `priority` (1–9). A `due_at` value creates both the due time and an absolute notification alarm.

```json
{
  "title": "Buy milk",
  "list_id": "stable-list-id",
  "due_at": "2026-08-07T09:00:00-07:00",
  "priority": 1
}
```

The result is the complete created reminder, including due and alarm metadata.

### `open_reminder`

Looks up the required reminder `id` through EventKit, then opens that exact reminder in Reminders. Success is returned only if lookup and bounded automation both succeed.

```json
{
  "id": "stable-reminder-id"
}
```

## Responses

Every tool returns a canonical envelope:

```json
{
  "ok": true,
  "tool": "query_reminders",
  "result": {
    "reminders": [],
    "returned_count": 0,
    "total_count": 0,
    "limit": 50,
    "has_more": false
  }
}
```

Reminder fields use snake_case and include `id`, `title`, `notes`, `due_at`, completion state/time, priority, list ID/title, creation/modification times, and alarms. All returned date-times are RFC3339.

See [MIGRATION-2.0.md](MIGRATION-2.0.md) for breaking changes from 1.x.

## Development

```bash
swift test
swift build -c release
```

The package pins `osaurus-plugin-sdk` to revision `21b4e133b365ff73c25d4a9db60d207c1888a6ab` until the corresponding SDK tag is available.
