# Energize

A menu bar switch that lets a MacBook keep working with the lid closed, without
cooking itself in your bag.

I run coding agents that take a while. I wanted to shut the laptop, put it in my
bag, and have the work carry on. macOS has a setting for that. The problem is
what happens next.

I left mine in a bag for about an hour with the setting on. The bag was hot when
I took it out and the fans were at full speed. The screen had stayed lit the
whole time behind the closed lid, because the setting that keeps the machine
awake says nothing about the backlight.

So this app does two things. It flips the setting, and it turns the screen off
once you stop typing. It also turns itself off again on a timer, on a low
battery, or when the machine gets hot, so you can't leave it on by accident.

## Installing it

You need macOS 13 or later and Apple's command line developer tools. If you have
never installed those, this is all of it. It is a free download from Apple.

```bash
xcode-select --install
```

Then build it:

```bash
git clone https://github.com/william-agehouse/energize.git && cd energize && ./build.sh
```

```bash
cp -R build/Energize.app /Applications/ && open /Applications/Energize.app
```

There is no prebuilt download, because I don't have an Apple developer
certificate. Building it is the one command above.

Nothing appears when it opens. It has no window and no Dock icon. Look for the
bolt in the menu bar at the top right.

## Using it

The bolt is hollow when sleep is normal and solid red when the lid can be
closed. Click it:

- **"Energize my MacBook"** puts up the standard macOS password box. Type your
  password once. Now you can shut the lid and put the laptop in a bag, and
  whatever is running keeps running.
- **"Let it sleep again"** puts everything back. This one never asks for a
  password.

The menu also shows how warm the machine thinks it is, so you can check before
you close the lid. Also there is a "How does this work?" item that opens a page
explaining what the app changes, what makes it stand down, and what to do if
something looks stuck.

If you ever want to clear the setting by hand, restart. It lives in memory and
is never written to your settings, so a restart always clears it.

## What makes it turn itself off

Five things, and the menu tells you which one happened.

| What | Default | Setting |
|---|---|---|
| Time limit ran out | 1 hour | "Turn off after": 30 min, 1 h, 2 h, no limit |
| Battery got low | below 15% | "Turn off below battery": 10%, 15%, 25%, never |
| Low Power Mode came on | always | none, the machine has been told to conserve so it steps aside |
| Machine got hot | always | none |
| The app stopped running | always | quit, logout, shutdown or a crash |

The time limit and the battery floor have to be chosen before you switch it on,
and the menu greys them out while it's running. That's deliberate. The watcher
carries the deadline and the floor inside itself, where nothing on disk can
extend them. To change either one, switch off and start again. Switching off is
free and never asks for a password.

The heat cutoff is a backstop, not protection. macOS publishes a coarse reading
of normal, warm, hot or very hot to any app that asks, and no permission is
needed for it. When it says hot, the switch flips back on its own. The laptop's
own fans and throttling still do the real work.

Quitting the app is the same as switching it off. The lock only lasts as long as
the app is running. The menu says so while it's on.

All of that only covers a lock this app switched on. If you set it by hand in a
terminal, there's no watcher behind it and nothing can undo it while you're
away. The menu says "No automatic safety net" when that's the case, and offers
"Add the safety net (asks for password)" to put one there.

## Turning the screen off

This is the part the other tools don't do, and it's the part that actually
matters for heat.

While it's on, the app watches how long it's been since you touched the keyboard
or trackpad. Once you stop, which is what happens the moment the laptop goes in
a bag, it puts the screen to sleep the same way macOS does on a normal lid
close. Any keypress brings it back, so it stays out of your way while you're
using the machine.

The delay is a menu choice, "Screen off when idle for", offering 30 seconds, 1
minute, 2 minutes or never. It defaults to 2 minutes, which is what macOS uses
on battery. That delay is time the screen spends lit inside a closed bag, so 30
seconds is the better pick for travel.

I measured it on 10 September 2026. Lid shut for four minutes, and macOS's own
power log recorded `Display is turned off` at 14:07:18 and `Display is turned
on` at 14:10:30 when I opened the lid. The screen was genuinely off, and it went
off about two minutes after the last keypress, as intended. You can check it on
your own machine with `./tools/screencheck.sh`.

**With an external display attached it leaves the screen alone.** Sleeping
displays is system-wide, so it would blank the monitor you're working on. macOS
already handles a closed lid properly in that situation by switching to
clamshell mode by itself, so there's nothing to do. The check is "is the
built-in the only active display", not a count of displays, because in clamshell
mode the built-in drops off the list and the external monitor is the only one
left. The menu says "External display, screen left alone" when this applies.

It doesn't try to detect the lid closing. The registry value that reports lid
state, `AppleClamshellState`, is latched on my machine and reads "closed" while
the lid is plainly open, so anything built on it would misfire. Time since last
input needs no permission and no private framework, and can't be wrong that way.

It also runs `caffeinate -ims`, which keeps the machine awake and stays out of
the way of the screen. The `-d` and `-u` flags are deliberately missing. Both of
those hold the display on, which is the opposite of what I want.

## Does any of this interrupt work that's running?

No. I measured six minutes, sampled once a second, with the lid shut and the
machine locked.

| Measured | Result |
|---|---|
| Gap between ticks | median 1.000s, worst 1.010s, none over 1.5s |
| Dropped seconds | 0 out of 360 |
| Fixed work per tick, to catch throttling | median 0.7 ms, worst 1.1 ms |
| Network reachable | 36 of 36, slowest 120 ms |
| Disk writes completing | 36 of 36, slowest 1 ms |
| Processor time used by the app being watched | climbed 204.6s to 210.2s |

macOS confirms the screen did go off and the machine did lock during that
window. `loginwindow` recorded lock requests at 14:21:35 and 14:23:15, with the
display off for 59 and 62 seconds.

So the locking happens at the display layer only. Nothing running is paused,
slowed or disconnected by it.

Being honest about scope: that's about two minutes of genuinely locked operation
and two lock/unlock transitions, not an overnight run, and the workload was
light. Reproduce it with `./tools/interrupt-test.py 360 > /tmp/interrupt-test.log`.

For comparison, the same test with the app switched off and the lid closed: work
froze for 60 seconds, then for 219 seconds, running about a tenth of the time.
There is no error message when that happens. Things just stop.

## The password

It asks for your password each time you switch it on, and never when you switch
it off.

If that gets annoying, there's a menu item, "Stop asking for my password". It
opens a Terminal window pointed at a script called `grant.sh` that ships inside
the app, and stops there. It doesn't run it. The app has no way to install the
rule itself. You read the script, you type your own password, and you see every
line of what happens.

You can skip the menu and run the same script yourself:

```bash
/Applications/Energize.app/Contents/Resources/grant.sh
```

It adds a rule letting exactly two commands run as root without a password: the
switch that stops your Mac sleeping, and the one that puts it back. The
arguments are spelled out in full and there are no wildcards, so nothing else is
covered. The worst it can be used for is keeping a Mac awake or letting it
sleep.

The rule goes to your account rather than to the app, because that's how sudo
works. Anything already running as you could use those two commands.

Undo it whenever you like, either with the "Ask for my password again" menu
item, or:

```bash
/Applications/Energize.app/Contents/Resources/grant.sh --remove
```

The script writes the rule to a temporary file and checks it with `visudo -c`
before installing it, because a sudoers file with a syntax error stops `sudo`
working entirely and fixing that needs `sudo`. It also refuses to touch
`/etc/sudoers` itself, and only ever adds a separate file in `/etc/sudoers.d`.

One trap, in case it's useful to somebody else: `sudo -n -l <command>` looks
like it answers "can this run without a password", and it doesn't. It answers
"is this command allowed at all", so on any Mac where you're an administrator it
says yes to everything, including `rm -rf`. I had the check wrong for a while
and the app believed it was password free on machines where it wasn't. It now
reads the `sudo -n -l` listing and looks for the `NOPASSWD` line, and both
places that use the answer fall back to the password box if the quiet route
fails.

## How it works

Changing the sleep setting needs an administrator password. Switching it on can
ask for one, because you're sitting there. Switching it off automatically can't,
because a laptop in a bag has nobody to type it.

So the one privileged step does two things at once. It flips the setting, and it
starts a small loop running as root that watches two files in
`~/.local/state/energize/`:

- `heartbeat`, which the app touches every 5 seconds while it's alive
- `revert`, which the app creates to say "put sleep back now"

If the revert file shows up, or the heartbeat goes more than 30 seconds stale,
the root loop restores sleep and exits. One password prompt per activation,
nothing stored, and no permanent change to what can run without a password.

Only one watcher may own the lock. Each activation stamps a number into a
`generation` file, and every watcher carries the number it was born with. A
watcher that sees a later number retires quietly without reverting, because a
newer one is now in charge and reverting would cancel it. Without that, starting
twice in one session leaves two watchers running and the older one can undo the
newer one's lock.

Three deliberate choices in there:

- The root loop never reads a command out of a file, and never kills a process
  id it found in one. The only thing it can be talked into doing is restoring
  sleep, which is the safe direction. So those files sitting in a folder any
  local process can write to don't grant anything.
- The loop's text travels as base64 straight out of the compiled binary, so no
  file on disk is executed as root. Editing something in that folder can't turn
  into root access next time.
- The exception is the `generation` file. Writing a very large number into it
  would make watchers retire, leaving the lock on with nothing behind it. That
  needs write access to your own home folder, the worst outcome is a Mac that
  stays awake, and the menu reports "No automatic safety net" when it happens.

### Why there's a watcher even if you install the rule

Every other app in this space installs a sudoers rule and relies on it. That's
what lets them offer a timer, since a countdown that fires while the laptop is
in a bag has nobody to type a password.

This one gets to the same place without needing that. The privileged step starts
the root loop, and the loop does the reverting when a limit is reached. If you
never install the rule, nothing on your Mac is left permanently able to change
power settings without a password.

The trade-off is real. The sudoers approach is more robust, because it's a
documented, supported mechanism, and the surviving root loop depends on how the
privileged step treats background processes. There's a note in `armCommand` in
the source recording what I measured and what to switch to if it ever breaks.

## Rebuilding

```bash
./build.sh
```

The source is one file, [`src/main.swift`](src/main.swift). The numbers worth
tuning, the heartbeat interval, the 30 second grace period, and how long to wait
for the watcher before falling back to a password prompt, are named constants
near the top.

## Which Macs

- macOS 13 Ventura or later.
- Any Mac laptop, Apple Silicon or Intel. It builds as a universal binary. The
  underlying setting is a standard macOS power management flag, not something
  model specific.
- It's built for laptops. On a Mac with no battery the battery floor never
  fires, because the code ignores an empty battery reading.

Two things worth knowing per machine. Fanless MacBook Airs have no way to move
heat out while shut, so the heat cutoff matters more there and does less. Also
on Intel Macs, clamshell mode needs the power adapter, while Apple Silicon
doesn't.

## What I haven't tested

I built and tested this on a MacBook Pro (Mac17,2) running macOS 26.

- Intel Macs are untested. The universal binary should run on them. Nobody has
  confirmed it.
- Long unattended runs are untested. The longest stretch I've measured is six
  minutes.
- I've measured it on battery and on mains. On mains: lid shut 87 seconds, 330
  samples over 329 seconds, worst gap 1.046s, zero dropped seconds, network and
  disk unaffected, and the time limit stood the lock down by itself afterwards.
- The root loop's four behaviours are tested with a stand-in for `pmset`, so no
  password was involved: a fresh heartbeat leaves sleep alone, a revert flag
  restores it, a stale heartbeat restores it, and a missing heartbeat restores
  it.

The first time you switch it on, check that the bolt goes solid red and that
`pmset -g | grep SleepDisabled` reports `1`.

## What it can't fix

- A fanless MacBook Air in a closed bag has nowhere to put its heat. Cutting the
  lock and killing the backlight helps. It doesn't cool the machine.
- Most of the heat is the processor under load, not the screen. Turning the
  screen off makes a closed bag meaningfully cooler, not cool.
- While it's on, the setting also blocks sleeping the Mac deliberately. That's
  what the setting does.

## Other people have built this

I'm not first. Worth knowing what's out there:

- [Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless) is the closest
  match. MIT, auto-off timer with a live countdown, battery floor, Low Power
  Mode awareness, and it reads the flag back so the menu can't lie. Uses a
  sudoers rule. It doesn't touch the display.
- [TY-teo/StayAwake](https://github.com/TY-teo/StayAwake) has the same use case,
  overnight coding agent runs. Sudoers rule, timed auto-off, crash-safe
  self-heal.
- [nghialuong/Lidless](https://github.com/nghialuong/Lidless) is a menu bar app
  aimed at coding agents.
- [Aarontaken/owly](https://github.com/Aarontaken/owly) is a minimal keep-awake
  including lid close.
- [demiaochen/caffeinate-disablesleep](https://github.com/demiaochen/caffeinate-disablesleep)
  puts `caffeinate` and `disablesleep` together in one click.
- Amphetamine is the big free one, not open source, with its own closed display
  mode.

Mine turns the screen off, and works without a standing sudoers rule. The
complaint people have about the raw `pmset` trick is that the internal display
keeps burning under a closed lid, and none of the ones above deal with it.

## Notes

- It uses `pmset -a`, which applies on battery and on mains. Earlier versions
  used `-b`, for battery only.
- To start it automatically: System Settings, General, Login Items, add
  Energize.

## License

MIT. Do what you like with it.
