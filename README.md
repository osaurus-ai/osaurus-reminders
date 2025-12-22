# osaurus-reminders

An Osaurus plugin for interacting with macOS Reminders.app via **EventKit** (native framework) and AppleScript (for UI control).

This plugin provides fast and reliable access using Apple's native `EventKit` framework for fetching, searching, and creating reminders. It uses AppleScript only for opening the Reminders application.

## Prerequisites

**Permissions are required.** The application using this plugin (e.g., Osaurus) requires two distinct permissions:

1. **Reminders Access** (Full Access):
   - **Why**: Required for `get_reminders`, `search_reminders`, `create_reminder`, and `get_lists` to read/write the database directly.
   - **How**: System Settings > Privacy & Security > Reminders > Toggle **ON** for your app.
   - _Host App Requirement_: `Info.plist` must include `NSRemindersFullAccessUsageDescription` (macOS 14+) or `NSRemindersUsageDescription`.
2. **Automation** (Apple Events):
   - **Why**: Required only for `open_reminder` to control the Reminders app UI.
   - **How**: System Settings > Privacy & Security > Automation > Expand your app > Toggle **ON** for "Reminders".
   - _Host App Requirement_: `Info.plist` must include `NSAppleEventsUsageDescription`.

## Tools

### `get_reminders`

Get reminders, optionally filtering by list, status, or date range.

**Parameters:**

- `limit` (optional): Maximum number of reminders to return (default: 50)
- `listName` (optional): Name of the list to fetch from
- `status` (optional): Filter by status: "incomplete", "completed", or "all" (default: "incomplete")
- `dueAfter` (optional): ISO date string to filter reminders due after this date
- `dueBefore` (optional): ISO date string to filter reminders due before this date

**Example:**

```json
{
  "limit": 10,
  "status": "incomplete",
  "listName": "Groceries"
}
```

### `search_reminders`

Search for reminders by title or notes.

**Parameters:**

- `searchText` (required): Text to search for
- `limit` (optional): Maximum number of reminders to return (default: 20)

**Example:**

```json
{
  "searchText": "project deadline"
}
```

### `create_reminder`

Create a new reminder.

**Parameters:**

- `title` (required): Title of the reminder
- `notes` (optional): Notes/description
- `listName` (optional): Name of the list to add the reminder to (default: default list)
- `dueDate` (optional): ISO date string (e.g., "2024-01-20T10:00:00Z")
- `priority` (optional): 1-9 (1 is highest, 5 is medium, 9 is low)

**Example:**

```json
{
  "title": "Buy milk",
  "listName": "Groceries",
  "priority": 1
}
```

### `get_lists`

Get all reminder lists.

**Example:**

```json
{}
```

### `open_reminder`

Open the Reminders app, optionally to a specific reminder.

**Parameters:**

- `id` (optional): The ID of the reminder to open

**Example:**

```json
{
  "id": "x-apple-reminder://..."
}
```

## Development

1. Build:

   ```bash
   swift build -c release
   cp .build/release/libosaurus-reminders.dylib ./libosaurus-reminders.dylib
   ```

2. Package (for distribution):

   ```bash
   osaurus tools package osaurus.reminders 0.1.0
   ```

   This creates `osaurus.reminders-0.1.0.zip` for distribution.

3. Install locally:
   ```bash
   osaurus tools install ./osaurus.reminders-0.1.0.zip
   ```

## Publishing

### Code Signing (Required for Distribution)

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  .build/release/libosaurus-reminders.dylib
```

### Package and Distribute

```bash
osaurus tools package osaurus.reminders 0.1.0
```

## Response Format

### Reminder Object

Tools return reminders in this format:

```json
{
  "id": "unique-id",
  "title": "Buy milk",
  "notes": "Organic only",
  "dueDate": "2024-01-20T10:00:00Z",
  "isCompleted": false,
  "priority": 5,
  "list": "Groceries"
}
```
