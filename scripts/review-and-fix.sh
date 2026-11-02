#! /usr/bin/env bash

set -euo pipefail

iteration=0
while true; do
    iteration=$((iteration + 1))
    echo "=== Iteration $iteration ===" >&2
    output=$(pi -p --provider anthropic --model claude-opus-5-5 --thinking medium "/skill:software-design please review the project and identify the 5 most impactful potentials to improve the software design and make the project more maintainable in the long run. Weigh findings higher, that also move functionality from clients to the core, improve performance, reduce app size or memory consumption at runtime. Instruct the pi agent to implement fixes and commit the changes using the command `pi -p --provider openrouter --model z-ai/glm-5.3-flash --thinking medium '<your-prompt>'`. Run the agents sequentially, so that there are no collisions between the individual agents. If there are no findings, just echo 'NO FINDINGS'" | tee /dev/stderr)

    if grep -qxF 'NO FINDINGS' <<<"$output"; then
        exit 0
    fi
done

