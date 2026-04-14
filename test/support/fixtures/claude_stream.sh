#!/usr/bin/env bash
set -euo pipefail

printf '{"type":"system","subtype":"init","session_id":"ses_claude_test_1"}\n'
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"applied the change"}]}}\n'
printf '{"type":"result","subtype":"success","session_id":"ses_claude_test_1","result":"done"}\n'
