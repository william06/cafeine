# Cafeine

Keeps your Mac awake, even with the lid closed, for a set amount of time
(for example, so Claude keeps working) and then puts everything back the way
it was. A terminal script plus a menu bar app, built only on tools that ship
with macOS.

> Experimental. Use it on a stable, well-ventilated surface, never inside a
> bag.

## Usage

```bash
sudo ./cafeine.sh 3h        # also 90m, 45 (minutes) or 1d
./cafeine.sh status         # current state
```

Ctrl+C ends early and restores everything.

The first time, install the backstop (see below):

```bash
sudo ./cafeine.sh install
```

## Menu bar app

**Cafeine** is an optional app with a coffee cup in the menu bar (a moon when
no session is running). It starts a session (30 min, 1 h, 3 h, 8 h or a
custom duration), shows the countdown, battery, heat and lid state, and can
end the session early.

```bash
./build.sh                          # builds build/Cafeine.app
open build/Cafeine.app              # or: cp -R build/Cafeine.app /Applications/
```

- It runs the installed copy of the script (`/usr/local/libexec/cafeine.sh`),
  so run `sudo ./cafeine.sh install` first, and again whenever you change the
  script.
- Starting asks for your password. Ending doesn't: the app creates
  `/tmp/cafeine-stop` and the script stops within a few seconds.
- Quitting the app doesn't end the session; reopen it and it picks it up.
- Building only needs the Command Line Tools, not Xcode. The icon is drawn in
  code (`app/icon.swift`) at build time.

## What a session does

- **Always:** `pmset disablesleep 1`, so the Mac doesn't sleep even with the
  lid closed. The display turns off when the session starts.
- **Lid closed:** turns the display off (with sleep disabled, macOS no longer
  does it on its own), freezes Slack, WhatsApp and Discord (`SIGSTOP`), mutes
  audio and turns on Low Power Mode. Opening the lid undoes it.
- **Battery:** Low Power Mode below 40 %, session ends below 15 %.
- **Heat:** Low Power Mode when thermal pressure is `Heavy`, session ends when
  it is critical.

All thresholds and the app list are in the "Settings" section at the top of
`cafeine.sh`.

## Recovery

Before each change, the script writes it to a journal
(`/var/db/cafeine/journal`). When the session ends it undoes what is listed
and deletes the journal.

If the script dies abruptly (a hang, `kill -9` or a shutdown), the launchd
backstop (`sudo ./cafeine.sh install`) checks every minute:

- If the session is no longer running, it undoes its changes right away.
- If it is still alive but 5 minutes past its end time, it undoes them too.
- It only resumes a frozen process if it is still the same one (same PID and
  same start time).

The backstop uses a copy at `/usr/local/libexec/cafeine.sh`. If you change
the script, run `install` again. To remove it: `sudo ./cafeine.sh uninstall`.

To undo by hand: `sudo ./cafeine.sh recover`, or as a last resort
`sudo pmset -a disablesleep 0`.

## Tests

```bash
bash tests/test.sh
```

They exercise the script's helpers with stubbed system commands, so they need
neither sudo nor a real session.

## License

[MIT](LICENSE).
