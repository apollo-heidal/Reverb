#!/usr/bin/env bash
set -euo pipefail

printf '{"type":"session.started","sessionID":"ses_test_123"}\n'
printf '{"type":"message","role":"assistant","content":[{"type":"text","text":"implemented the feature"}]}\n'
