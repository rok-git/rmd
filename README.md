# rmd

`rmd` is a small Swift command line tool for reading and writing the macOS
Reminders database through EventKit.

## Scope

The first version focuses only on Reminders. Calendar integration is out of
scope. Human-readable output is the default, and `--json` is available for
scripts.

## Commands

```sh
rmd list
rmd list --list "Work"
rmd list --today
rmd list --overdue
rmd list --next 7
rmd list --json

rmd add "Buy milk"
rmd add "Buy milk" --due "2026-06-18 18:00" --list "Shopping" --note "Low fat"

rmd edit <reminder-id> --title "Buy milk and eggs"
rmd edit <reminder-id> --due "2026-06-19 09:00"
rmd edit <reminder-id> --clear-due

rmd done <reminder-id>
rmd undone <reminder-id>

rmd lists
```

## Permissions

The first command that touches Reminders asks macOS for full Reminders access.
If access is denied, enable it in System Settings > Privacy & Security >
Reminders.

## Build

```sh
swift build
```

Run during development:

```sh
swift run rmd lists
```
