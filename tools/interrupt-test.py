#!/usr/bin/env python3
"""Does closing the lid interrupt work that is already running?

Logs once a second. The signal that matters is `gap` — the wall-clock time since
the previous tick. If the machine is genuinely still working, every gap stays
near 1.0 second. Any stall, suspend or throttle shows up as a gap larger than
that, and nothing else has to be inferred.

Also samples, every ten seconds, the three things a coding agent actually needs:
network reachability, disk writes completing, and whether the Claude app is still
accumulating processor time.

  ./tools/interrupt-test.py 360 > /tmp/interrupt-test.log
"""
import hashlib, json, socket, subprocess, sys, time, os

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 360
BLOCK = b"x" * 500_000
SCRATCH = "/tmp/interrupt-test-disk-probe"


def shell(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=8).stdout.strip()
    except Exception:
        return ""


def claude_cpu_seconds():
    """Processor time used by the Claude app, in seconds. If this keeps climbing
    while the lid is shut, the app is genuinely running."""
    out = shell("ps -axo pid,cputime,comm | grep -i 'Claude.app/Contents/MacOS/Claude' "
                "| grep -v grep | head -1")
    if not out:
        return None
    try:
        clock = out.split()[1]
        parts = [float(p) for p in clock.replace("-", ":").split(":")]
        total = 0.0
        for p in parts:
            total = total * 60 + p
        return total
    except Exception:
        return None


def network_ok():
    started = time.perf_counter()
    try:
        with socket.create_connection(("api.anthropic.com", 443), timeout=4):
            return True, round((time.perf_counter() - started) * 1000)
    except Exception:
        return False, round((time.perf_counter() - started) * 1000)


def disk_ok():
    started = time.perf_counter()
    try:
        with open(SCRATCH, "w") as handle:
            handle.write(str(time.time()))
            handle.flush()
            os.fsync(handle.fileno())
        return True, round((time.perf_counter() - started) * 1000)
    except Exception:
        return False, round((time.perf_counter() - started) * 1000)


start = time.time()
previous = start
tick = 0
print(json.dumps({"event": "start", "at": time.strftime("%H:%M:%S"),
                  "duration": DURATION}), flush=True)

while time.time() - start < DURATION:
    now = time.time()
    gap = round(now - previous, 3)
    previous = now

    # Fixed amount of work; how long it takes reveals throttling.
    work_started = time.perf_counter()
    hashlib.sha256(BLOCK).hexdigest()
    work_ms = round((time.perf_counter() - work_started) * 1000, 2)

    row = {"t": time.strftime("%H:%M:%S"), "elapsed": round(now - start, 1),
           "gap": gap, "work_ms": work_ms}

    if tick % 10 == 0:
        net, net_ms = network_ok()
        dsk, dsk_ms = disk_ok()
        row.update({"net": net, "net_ms": net_ms, "disk": dsk, "disk_ms": dsk_ms,
                    "claude_cpu": claude_cpu_seconds(),
                    "sleep_disabled": "1" in shell("pmset -g | grep SleepDisabled"),
                    "helper_alive": os.path.exists(
                        os.path.expanduser("~/.local/state/energize/helper-alive")),
                    "battery": shell("pmset -g batt | grep -oE '[0-9]+%' | head -1")})

    print(json.dumps(row), flush=True)
    tick += 1
    # Sleep to the next whole second rather than drifting.
    time.sleep(max(0, (start + tick) - time.time()))

print(json.dumps({"event": "end", "at": time.strftime("%H:%M:%S")}), flush=True)
