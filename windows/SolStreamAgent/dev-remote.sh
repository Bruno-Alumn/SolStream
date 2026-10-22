#!/bin/sh
# Build and run the agent on the Windows dev box over SSH.
#
# The agent MUST run in the interactive session. A process started over SSH
# lands in session 0, which has a phantom 1024x768 display and cannot see the
# real desktop's windows at all — EnumWindows returns nothing. So we build over
# SSH but launch through a scheduled task marked interactive (/it), which runs
# in the logged-on user's session. Sockets are not session-isolated, so the
# agent can still be driven over loopback from an SSH session.
set -e
# Your PC, your key and where the repository is on it. Set these in your
# shell profile rather than editing them here, so nothing personal is committed:
#   export SOLSTREAM_HOST=you@your-pc   SOLSTREAM_KEY=~/.ssh/your_key
#   export SOLSTREAM_REPO='C:\Users\you\Desktop\SolStream'
HOST=${SOLSTREAM_HOST:-you@100.101.102.103}
KEY=${SOLSTREAM_KEY:-$HOME/.ssh/id_ed25519_pc}
REPO=${SOLSTREAM_REPO:-'C:\Users\you\Desktop\SolStream'}
SSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=20 $HOST"

case "${1:-build}" in
  build)
    $SSH "cd $REPO && cmake --build build --target SolStreamAgent --config Release"
    ;;
  start)
    $SSH 'schtasks /run /tn SolStreamAgentDev'
    ;;
  stop)
    $SSH 'taskkill /IM SolStreamAgent.exe /F 2>nul & exit 0'
    ;;
  log)
    $SSH 'type "%LOCALAPPDATA%\SolStream\solstream.log"'
    ;;
  restart)
    "$0" stop || true
    "$0" build
    "$0" start
    ;;
  *)
    echo "usage: $0 {build|start|stop|restart|log}" >&2
    exit 1
    ;;
esac
