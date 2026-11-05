#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

cleanup_question ex-ts-04
question_state_clear ex-ts-04
