#!/bin/bash
set -euo pipefail

cli=${1:-.build/debug/macip}
python3 - "$cli" <<'PY'
import os
import re
import pty
import select
import subprocess
import time
import sys
import tempfile

cli = os.path.abspath(sys.argv[1])

def run(*args, env=None, timeout=10):
    return subprocess.run([cli, *args], text=True, capture_output=True,
                          env={**os.environ, **(env or {})}, timeout=timeout)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

r = run('--version')
require(r.returncode == 0 and re.fullmatch(r'macip \d+\.\d+\.\d+\n?', r.stdout) is not None, 'version is not semantic')
require(run('--help').returncode == 0, 'help failed')
for args in [(), ('a',), ('addr',), ('address',), ('route',), ('a', '--all')]:
    r = run(*args)
    require(r.returncode == 0, f"command failed: {args!r}: {r.stderr}")

r = run('a', '--all')
require('lo0 ' in r.stdout, '--all should include loopback')
r = run('a', 'show', 'lo0')
require(r.returncode == 0 and '127.0.0.1' in r.stdout, 'interface selection failed')
r = run('a', 'show', 'macip_nonexistent_interface')
require(r.returncode != 0 and 'No interface named' in r.stderr, 'unknown interface accepted')
for args in [('--unknown',), ('a', 'show'), ('a', 'show', 'lo0', 'extra'), ('route', 'extra')]:
    r = run(*args)
    require(r.returncode != 0, f"invalid args accepted: {args!r}")

# shell=False is deliberate: option text must remain inert input to the CLI.
with tempfile.TemporaryDirectory(prefix='macip-cli-') as tmp:
    marker = os.path.join(tmp, 'should-not-exist')
    r = run('a', 'show', f"x; touch {marker}")
    require(r.returncode != 0 and not os.path.exists(marker), 'argument was executed by a shell')

# Non-TTY output never contains ANSI, even with -c.
r = run('-c', 'a')
require(r.returncode == 0 and '\x1b[' not in r.stdout, 'color leaked into pipe')

# Exercise color gating on an actual pseudo-terminal.
def pty_output(env):
    master, slave = pty.openpty()
    child_env = os.environ.copy()
    child_env.pop('NO_COLOR', None)
    child_env.update(env)
    proc = subprocess.Popen([cli, '-c', 'a'], stdin=subprocess.DEVNULL,
                            stdout=slave, stderr=slave, env=child_env,
                            start_new_session=True)
    os.close(slave)
    chunks = []
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            if proc.poll() is not None and not readable:
                break
        proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        return proc.returncode, b''.join(chunks).decode(errors='replace')
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise SystemExit('PTY command timed out')
    finally:
        os.close(master)

code, output = pty_output({'TERM': 'xterm-256color'})
require(code == 0 and '\x1b[' in output, 'TTY color was not enabled')
for env in [{'TERM': 'xterm-256color', 'NO_COLOR': '1'}, {'TERM': 'dumb'}]:
    code, output = pty_output(env)
    require(code == 0 and '\x1b[' not in output, f'color was not disabled for {env!r}')

# Control characters in rejected arguments must not be passed through to stderr.
r = run('--bad\x1b[31m')
require(r.returncode != 0 and '\x1b' not in r.stderr, 'control character was not sanitized')
print('CLI checks passed')
PY
