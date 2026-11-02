#! /usr/bin/env bash

set -euo pipefail

# Quoted heredoc: bash leaves the backticks in the prompt alone.
read -r -d '' prompt <<'EOF' || true
/skill:software-design please review the project and identify the 5 most impactful potentials to improve the software design and make the project more maintainable in the long run. Weigh findings higher, that also move functionality from clients to the core, improve performance, reduce app size or memory consumption at runtime.

Instruct the pi agent to implement fixes and commit the changes using the command `pi -p --provider anthropic --model claude-haiku-5-5 --thinking medium '<your-prompt>'`, replacing <your-prompt> with the actual instructions you want to give the agent. Run the agents sequentially, so that there are no collisions between the individual agents.

Once all agents have finished, run /skill:code-review since @BASE@, using your prompts to the agents as the spec. Then hand all findings to a single fixup agent: `pi -p --provider anthropic --model claude-sonnet-5-5 --thinking medium '<your-prompt>'`.

bash may only write to /tmp: create files with the write tool, and tell every agent to do the same.

If there are no findings, just echo 'NO FINDINGS'
EOF

iteration=0
while true; do
    iteration=$((iteration + 1))
    echo "=== Iteration $iteration ===" >&2
    output=$(pi -p --provider anthropic --model claude-opus-5-5 --thinking medium "${prompt//@BASE@/$(git rev-parse HEAD)}" | tee /dev/stderr)

    if grep -qxF 'NO FINDINGS' <<<"$output"; then
        exit 0
    fi
done
