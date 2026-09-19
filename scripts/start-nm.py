#!/usr/bin/env python3
"""Double-fork daemonizer for NetworkManager (and other long-running services).

Pattern:
  1. First fork: parent exits, child becomes orphan (reparented to PID 1).
  2. setsid() to detach from any controlling terminal / process group.
  3. Second fork: prevents reacquiring a terminal.
  4. chdir /, umask 0, redirect stdio to /dev/null + log file.
  5. exec the real daemon.
"""
import os, sys

LOG = "/var/log/nm.log"
CMD = ["/usr/sbin/NetworkManager", "--no-daemon"]


def main():
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    os.chdir("/")
    os.umask(0)
    sys.stdin = open("/dev/null", "r")
    log_fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    os.close(log_fd)
    os.execvp(CMD[0], CMD)


if __name__ == "__main__":
    main()