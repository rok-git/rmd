# rmd

`rmd` is a small Swift command line tool for reading and writing the macOS
Reminders database through EventKit.

## Scope

The first version focuses only on Reminders. Calendar integration is out of
scope. Human-readable output is the default, and `--json` is available for
scripts.

## Commands

List reminders:

```sh
rmd list
rmd list --list "Work"
rmd list --yesterday
rmd list --today
rmd list --tomorrow
rmd list --overdue
rmd list --next 7
rmd list --due-from "2026-06-18"
rmd list --due-to "2026-06-30"
rmd list --due-from "2026-06-18" --due-to "2026-06-30"
rmd list --completed
rmd list --completed --yesterday
rmd list --completed --today
rmd list --completed-from "2026-06-01" --completed-to "2026-06-18"
rmd list --limit 10
rmd list --json
```

Show one reminder, including its note:

```sh
rmd show <reminder-id>
rmd show <reminder-id> --json
```

Create and edit reminders:

```sh
rmd add "Buy milk"
rmd add "Buy milk" --due "2026-06-18 18:00" --list "Shopping" --note "Low fat"
rmd add "Buy milk" --verbose

rmd edit <reminder-id> --title "Buy milk and eggs"
rmd edit <reminder-id> --due "2026-06-19 09:00"
rmd edit <reminder-id> --clear-due
```

Delete, complete, or reopen reminders:

```sh
rmd delete <reminder-id>
rmd delete <reminder-id> <reminder-id>
rmd delete <reminder-id> --verbose

rmd done <reminder-id>
rmd done <reminder-id> --verbose
rmd undone <reminder-id>
```

List reminder lists:

```sh
rmd lists
rmd lists --json
```

Reminder IDs can be full EventKit identifiers or short unique prefixes. The
default table output shows the first 8 characters, and mutation commands accept
prefixes with at least 4 characters when they uniquely identify one reminder.

Mutation commands are quiet on success. Use `-v` or `--verbose` to print a
confirmation, or `--json` to print the changed reminder as JSON.

`delete` accepts one or more reminder IDs and asks for confirmation before each
reminder is removed. Answer `y` or `yes` to delete; any other answer skips it.

Date values use `yyyy-MM-dd` or `yyyy-MM-dd HH:mm`. A date-only upper bound,
such as `--due-to "2026-06-30"`, includes the whole day. Relative filters like
`--yesterday`, `--today`, and `--tomorrow` apply to due dates by default, and to
completion dates when combined with `--completed`.

Use `--limit COUNT` to print only the first COUNT reminders after filtering and
sorting.

If `rmd add` is run without `--list`, `RMD_DEFAULT_LIST` can select the target
list:

```sh
export RMD_DEFAULT_LIST="Shopping"
rmd add "Buy milk"
```

## Permissions

The first command that touches Reminders asks macOS for full Reminders access.
If access is denied, enable it in System Settings > Privacy & Security >
Reminders.

## Build

```sh
make
```

Build an optimized binary and copy it to a directory on your `PATH`:

```sh
make release
make install
```

Use a different destination, such as `~/bin/rmd`, if that is where you keep
personal command line tools:

```sh
make install PREFIX="$HOME"
```

You can still call SwiftPM directly:

```sh
swift build
swift build -c release
```

Run during development:

```sh
make run
```
