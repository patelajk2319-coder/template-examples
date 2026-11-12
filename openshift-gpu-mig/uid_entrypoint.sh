#!/bin/bash
# OpenShift S2I-style UID entrypoint.
#
# restricted-v2 injects a random UID with no /etc/passwd entry, which breaks
# Go's os/user.Current() (the Coder agent calls it), HOME resolution, sudo,
# ssh-keygen, npm, etc. Append a passwd entry for the runtime UID at startup.
# Requires the image to have made /etc/passwd group-writable (see Dockerfile
# in README.md).
set -e

USER_ID=$(id -u)

if ! getent passwd "${USER_ID}" >/dev/null 2>&1; then
  echo "coder:x:${USER_ID}:0:Coder user:/home/coder:/bin/bash" >> /etc/passwd 2>/dev/null || true
fi

export HOME=/home/coder
export USER=coder

# No args (e.g. `oc exec -it`) -> bash; otherwise exec the requested command
# (workspace pods pass ["sh","-c", coder_agent.main.init_script]).
if [ "$#" -eq 0 ]; then
  exec /bin/bash
fi
exec "$@"
