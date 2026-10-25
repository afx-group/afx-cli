#!/bin/bash
# DEPRECATED NAME: afx-open.sh was renamed afx-terminal-agent-launcher.sh on 2026-10-14. This only forwards.
exec "$(cd "$(dirname "$0")" && pwd)/afx-terminal-agent-launcher.sh" "$@"