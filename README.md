# zmx - session persistence for terminal processes

## usage

- `zmx attach <session_name>` - create or attach to a session
- `zmx detach` (or Ctrl+b + d) - detach from session while keeping pty alive
- `zmx list` - list sessions
- `zmx kill <session_name>` kill pty and all clients attached to session
