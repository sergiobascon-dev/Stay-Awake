#!/bin/bash
# Invoked only after the LaunchAgent verifies the sealed bundle's signature.
# All user-session recovery (including audio) runs as the user, never root.
set -euo pipefail
CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
exec "$CONTENTS/MacOS/Insomnia" --local-recovery-poll
