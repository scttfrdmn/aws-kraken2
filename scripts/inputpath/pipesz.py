#!/usr/bin/env python3
"""The input-path sweep's pipe-size wrapper (docs/inputpath.md, "The pipe"; #90).

Usage: pipesz.py BYTES|default RECORD CMD [ARGS...]

Raises the pipe on stdout (fd 1) to BYTES with fcntl F_SETPIPE_SZ (Linux; capped by
/proc/sys/fs/pipe-max-size for an unprivileged process), reads the size back with F_GETPIPE_SZ,
writes one line "requested=<BYTES|default> actual=<bytes> max=<pipe-max-size>" to RECORD, then
execs CMD with the same fds, so the decoder writes straight into the resized pipe. With
"default" nothing is changed and the default size is recorded (the same wrapper, so both arms
pay the same startup). Exit 3 if stdout is not a pipe or the size cannot be set: a point that
asked for a size it did not get is never measured as that size.
"""
import fcntl
import os
import stat
import sys

F_SETPIPE_SZ, F_GETPIPE_SZ = 1031, 1032   # linux/fcntl.h (python 3.9's fcntl lacks the names)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    want, rec, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
    if not stat.S_ISFIFO(os.fstat(1).st_mode):
        sys.stderr.write("pipesz: stdout is not a pipe\n")
        return 3
    try:
        mx = int(open("/proc/sys/fs/pipe-max-size").read().strip())
    except OSError:
        mx = -1
    try:
        if want != "default":
            fcntl.fcntl(1, F_SETPIPE_SZ, int(want))
        got = fcntl.fcntl(1, F_GETPIPE_SZ)
    except OSError as e:
        sys.stderr.write(f"pipesz: F_SETPIPE_SZ {want}: {e}\n")
        return 3
    if want != "default" and got < int(want):
        sys.stderr.write(f"pipesz: asked {want}, got {got}\n")
        return 3
    with open(rec, "w") as f:
        f.write(f"requested={want} actual={got} max={mx}\n")
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    sys.exit(main())
