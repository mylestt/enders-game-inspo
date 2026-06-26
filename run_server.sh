#!/usr/bin/env bash
# Runs the dedicated server on a Linux VPS, kept alive in a tmux session so it
# survives you logging out of SSH.
#
# Usage:  ./run_server.sh [port]
# Stop:   tmux kill-session -t gameserver

PORT="${1:-7000}"
BINARY="./enders_server.x86_64"   # must match the name you export from Godot
ADMIN_FILE="${ADMIN_FILE:-/root/enders_admin_commands.txt}"
ADMIN_KEY="${ADMIN_KEY:-}"
MIN_PLAYERS="${MIN_PLAYERS:-2}"
STARTING_CASH="${STARTING_CASH:-200000}"
POINTS_TO_WIN="${POINTS_TO_WIN:-8}"
ROUND_TIME="${ROUND_TIME:-0}"
MAP="${MAP:-diamond}"   # map id from MapGenerator.MAPS (e.g. diamond, 2v2)

if [ ! -f "$BINARY" ]; then
  echo "Binary not found: $BINARY"
  echo "Export a Linux build from Godot named enders_server.x86_64 (or edit BINARY above)."
  exit 1
fi

chmod +x "$BINARY" 2>/dev/null
touch "$ADMIN_FILE" 2>/dev/null

CMD="$BINARY --headless -- --server --port $PORT --admin-file $ADMIN_FILE --min-players $MIN_PLAYERS --starting-cash $STARTING_CASH --points-to-win $POINTS_TO_WIN --round-time $ROUND_TIME --map $MAP"

if [ -n "$ADMIN_KEY" ]; then
  CMD="$CMD --admin-key $ADMIN_KEY"
fi

if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t gameserver 2>/dev/null
  tmux new-session -d -s gameserver "$CMD"
  echo "Server started in tmux session 'gameserver' on UDP $PORT."
  echo "Rules: min_players=$MIN_PLAYERS starting_cash=$STARTING_CASH points_to_win=$POINTS_TO_WIN round_time=$ROUND_TIME map=$MAP"
  echo "Admin file: $ADMIN_FILE"
  echo "Watch it:  tmux attach -t gameserver    (detach: Ctrl+B then D)"
  echo "Stop it:   tmux kill-session -t gameserver"
else
  echo "tmux not installed; running in the foreground (will stop when you log out)."
  echo "Install tmux to keep it alive:  sudo apt install -y tmux"
  $CMD
fi
