#!/bin/bash
# Did the screen actually go off? Reads the display on/off events macOS records
# itself, which is the only reading that turned out to be trustworthy.
#
#   ./tools/screencheck.sh          # last 20 events
#   ./tools/screencheck.sh 14:00 15:00   # events in a window today
#
# An earlier version of this script sampled IOMobileFramebuffer power state and
# backlight brightness once a second. Both are useless here: brightness reports
# the user's setting rather than actual output, and that power state never
# changes on display sleep. It reported the screen lit for four minutes while
# macOS's own log showed it off for the last two and a half.
if [ -n "$1" ] && [ -n "$2" ]; then
  TODAY=$(date +%Y-%m-%d)
  pmset -g log | grep -iE "display is turned" \
    | awk -v d="$TODAY" -v a="$1" -v b="$2" '$1 == d && $2 >= a":00" && $2 <= b":00"'
else
  pmset -g log | grep -iE "display is turned" | tail -20
fi
