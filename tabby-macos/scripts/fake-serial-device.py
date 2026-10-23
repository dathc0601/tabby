#!/usr/bin/env python3
"""A pretend serial device for TabbyMac's manual checks (M9 in docs/MANUAL-CHECKS.md).

It opens a pseudo-terminal and plays the device on one end; TabbyMac opens the other end
(printed at start, e.g. /dev/ttys012) as if it were /dev/cu.*. With --link PATH it keeps a
symlink to that end, so a profile can name a path that stays the same across restarts.
Ctrl-C (or killing it) is unplugging the device.

What it answers, line by line (a line ends with CR or LF):
  AT        OK
  ATI       an identification line, then OK
  login     a "login: " prompt; the next line is taken as the user name
  bin       the bytes 00..1f, for the hexdump output mode
  anything  "you said: <line>"
Every chunk it receives is printed here as Python bytes, to check newline and hex modes.
"""
import argparse
import os
import select
import signal
import sys


def unplug(*_):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--link", help="keep a symlink at this path pointing to the device")
    args = parser.parse_args()
    signal.signal(signal.SIGINT, unplug)
    signal.signal(signal.SIGTERM, unplug)

    primary, replica = os.openpty()
    path = os.ttyname(replica)
    if args.link:
        if os.path.islink(args.link):
            os.unlink(args.link)
        os.symlink(path, args.link)
    print(f"device: {path}" + (f" (linked from {args.link})" if args.link else ""), flush=True)

    line = b""
    waiting_for_user = False
    try:
        while True:
            ready, _, _ = select.select([primary], [], [], 1.0)
            if not ready:
                continue
            try:
                chunk = os.read(primary, 4096)
            except OSError:
                continue  # nobody has the device open yet
            if not chunk:
                continue
            print(f"received {chunk!r}", flush=True)
            for byte in chunk:
                if byte in (0x0D, 0x0A):
                    if line or byte == 0x0D:
                        reply = answer(line.decode(errors="replace").strip(), waiting_for_user)
                        waiting_for_user = reply.endswith(b"login: ")
                        os.write(primary, reply)
                    line = b""
                else:
                    line += bytes([byte])
    except KeyboardInterrupt:
        pass
    finally:
        if args.link and os.path.islink(args.link):
            os.unlink(args.link)
        os.close(primary)
        os.close(replica)
        print("unplugged", flush=True)


def answer(text, waiting_for_user):
    if waiting_for_user:
        return f"Welcome, {text}\r\n$ ".encode()
    upper = text.upper()
    if upper == "AT":
        return b"OK\r\n"
    if upper == "ATI":
        return b"TabbyMac fake serial device 1.0\r\nOK\r\n"
    if text == "login":
        return b"login: "
    if text == "bin":
        return bytes(range(0x20)) + b"\r\n"
    if not text:
        return b""
    return f"you said: {text}\r\n".encode()


if __name__ == "__main__":
    sys.exit(main())
