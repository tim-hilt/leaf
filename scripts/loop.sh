#!/usr/bin/env bash
# Usage: scripts/loop.sh <project-directory>

set -uo pipefail

FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

format_elapsed() {
  local total=$1 minutes=$(($1 / 60)) seconds=$(($1 % 60))
  if ((minutes > 0)); then echo "${minutes}m ${seconds}s"; else echo "${seconds}s"; fi
}

# Most recent status message, rendered with a spinner and an elapsed timer.
status_message=""
status_start=0
status_active=0
spinner_pid=""

status_set() {
  status_stop >/dev/null
  status_message=$1
  status_start=$(date +%s)
  status_active=1
  [[ -t 1 ]] || return 0

  (
    frame=0
    while :; do
      printf '\r\033[K%s %s (%s)' "${FRAMES[frame++ % ${#FRAMES[@]}]}" "$status_message" \
        "$(format_elapsed $(($(date +%s) - status_start)))"
      sleep 0.1
    done
  ) &
  spinner_pid=$!
}

# Replaces the live line with a final line without spinner.
# Sets status_elapsed to the final elapsed time; no-op if no status is active.
status_stop() {
  ((status_active)) || return 0
  status_active=0
  if [[ -n $spinner_pid ]]; then
    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    spinner_pid=""
  fi
  status_elapsed=$(format_elapsed $(($(date +%s) - status_start)))
  [[ -t 1 ]] && printf '\r\033[K'
  echo "$status_message ($status_elapsed)"
}

trap '[[ -n $spinner_pid ]] && kill "$spinner_pid" 2>/dev/null' EXIT

# Usage: run_pi <provider> <model> <thinking> <prompt>
# Sets pi_output to the combined pi output; exits on failure.
run_pi() {
  pi_output=$(pi -p "$4" --provider "$1" --model "$2" --thinking "$3" </dev/null 2>&1)
  local code=$?
  if ((code != 0)); then
    status_stop
    printf 'pi exited with status %s\n\n%s\n' "$code" "$pi_output" >&2
    exit 1
  fi
}

# Appends a titled section to the log file.
log_section() {
  printf '%s\n\n%s\n\n---\n\n' "$1" "$2" >>"$log_file"
}

directory=${1:-} # kept as given, so paths stay relative to the cwd
if [[ -z $directory ]]; then
  echo "Usage: scripts/loop.sh <project-directory>" >&2
  exit 2
fi

tasks_dir="$directory/issues"
if [[ ! -d $tasks_dir ]]; then
  echo "No such directory: $tasks_dir" >&2
  exit 1
fi

mkdir -p logs
log_file="logs/$(basename "$(cd "$directory" && pwd)").loop.log"

shopt -s nullglob dotglob
tasks=()
for path in "$tasks_dir"/*.md; do # glob expansion is sorted
  [[ -f $path ]] && tasks+=("$path")
done
shopt -u nullglob dotglob

implemented=0

for task_file in ${tasks[@]+"${tasks[@]}"}; do
  # Check the current `**Status:**` line only; earlier implementations may change later tasks.
  grep -Eiq $'^\\*{0,2}Status:\\*{0,2}[ \t]*ready-for-agent[ \t]*\r?$' "$task_file" || continue

  status_set "Implementing $task_file"

  run_pi anthropic claude-sonnet-5-5 high \
    "/skill:tdd implement the task described in @$task_file. Apply software-design best practices during the implementation. Tick off all completed bullet points in $task_file. Set its Status line to in-review when you're finished. Commit all changes using the commit-message 'Implement $task_file'."

  implemented=$((implemented + 1))
  status_stop
  log_section "$task_file implemented in $status_elapsed" "$pi_output"
done

if ((implemented == 0)); then
  echo "No ready-for-agent tasks found."
  exit 0
fi

spec_file="$directory/spec.md"

status_set "Reviewing $spec_file"

run_pi anthropic claude-opus-5-5 high \
  "/skill:software-design the last commits implemented the tickets in @$tasks_dir. Please review these commits according to @$spec_file. Also consider @$log_file to understand how we got to the current state. Pay special attention to correctness and simplicity. Fix found issues right away. If an issue is fully implemented, then please set its Status line to 'done'. Commit your changes using the commit-message 'Reviewed $spec_file'."

status_stop
log_section "$spec_file reviewed in $status_elapsed" "$pi_output"
