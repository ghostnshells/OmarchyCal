# Omarchy Calendar Popup

A theme-aware calendar panel for the Omarchy shell. It opens as a centered
Quickshell popup and combines a month grid with a selected-day agenda.

https://github.com/user-attachments/assets/e854540a-5f78-4210-a73b-d1c0d7d3606c

## Features

- Omarchy theme-aware colors, typography, borders, and popup styling
- Month grid with event-color dots and a day agenda
- Keyboard day navigation: `←` / `→` one day, `↑` / `↓` one week
- `Shift` + `←` / `→` changes month; `T` jumps to today; `R` refreshes
- Read-only Google Calendar display using a private iCal/ICS feed
- Multiple feeds supported, separated by commas or newlines
- Heuristic event categories: urgent, meetings, work, health, personal,
  social, travel, and other
- Demo events when no feed is configured

This plugin is **view-only**. Google Calendar's private ICS feed cannot create
or edit events. Events created elsewhere sync into the popup when Google
refreshes the feed.

## Install

On Omarchy, run:

```sh
omarchy plugin add https://github.com/ghostnshells/OmarchyCal.git --enable
```

## Open with `SUPER+ALT+C`

Plugin installation enables the panel, but Omarchy user keybindings are kept
separately. Add this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + C", "Calendar popup", "omarchy-shell shell toggle ghostnshells.calendar-popup")
```

Then reload Hyprland:

```sh
hyprctl reload
```

If `SUPER+ALT+C` is already assigned in your setup, unbind that existing
binding before adding this one.

## Connect Google Calendar (read-only)

1. In Google Calendar, open **Settings → Settings for my calendars → [calendar]
   → Integrate calendar**.
2. Copy **Secret address in iCal format**. Treat this URL like a password: it
   grants access to the calendar feed.
3. Open the popup and press `E`.
4. Paste the URL and choose **CTRL+ENTER TO SAVE**. For multiple calendars,
   separate their URLs with commas or newlines.

The feed is fetched on open and when `R` is pressed. The plugin stores the URL
locally in `~/.local/state/omarchy/settings/calendar-popup.json`; it is not
included in this repository.

## Controls

| Key | Action |
| --- | --- |
| `←` / `→` | Previous / next day |
| `↑` / `↓` | Previous / next week |
| `Shift` + `←` / `→` | Previous / next month |
| `T` | Select today |
| `E` | Edit calendar feed settings |
| `R` | Refresh calendar feeds |
| `Esc` | Close |

Click any date in the grid to see its agenda. Clicking a dimmed date from an
adjacent month follows it into that month.

## Event colors

Events are categorized by matching words in their title, description, and
location. The category determines the dot and agenda accent color. Events that
do not match a category use the current Omarchy theme accent. This is a visual
heuristic; it does not change event data in Google Calendar.

## Uninstall

```sh
omarchy plugin disable ghostnshells.calendar-popup
omarchy plugin remove ghostnshells.calendar-popup
```

Remove the `o.bind(...)` line from `~/.config/hypr/bindings.lua` to remove the
hotkey. To clear the saved feed URL, remove
`~/.local/state/omarchy/settings/calendar-popup.json`.

## Development

The plugin is a normal Omarchy shell plugin with `manifest.json` at the
repository root. Validate it with:

```sh
omarchy plugin validate .
qmllint Panel.qml
node --test
```

## License

MIT. See [LICENSE](LICENSE).
