// Usage: node loop.ts <project-directory>

import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

function formatElapsed(ms: number): string {
  const total = Math.floor(ms / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;

  return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

interface Status {
  timer?: NodeJS.Timeout;
  message: string;
  start: number;
  frame: number;
  render(): void;
  set(message: string): void;
  stop(): string | undefined;
}

// Most recent status message, rendered with a spinner and an elapsed timer.
const status: Status = {
  message: "",
  start: 0,
  frame: 0,

  render(): void {
    const spinner = FRAMES[this.frame++ % FRAMES.length];
    process.stdout.write(
      `\r\x1b[K${spinner} ${this.message} (${formatElapsed(Date.now() - this.start)})`,
    );
  },

  set(message: string): void {
    this.stop();
    this.message = message;
    this.start = Date.now();

    if (!process.stdout.isTTY) {
      this.timer = setInterval(() => {}, 1 << 30); // marks status as active

      return;
    }

    this.render();
    this.timer = setInterval(() => this.render(), 100);
  },

  // Replaces the live line with a final line without spinner.
  // Returns the final elapsed time, or undefined if no status was active.
  stop(): string | undefined {
    if (!this.timer) return undefined;
    clearInterval(this.timer);
    this.timer = undefined;
    const elapsed = formatElapsed(Date.now() - this.start);
    console.log(`${process.stdout.isTTY ? "\r\x1b[K" : ""}${this.message} (${elapsed})`);

    return elapsed;
  },
};

class Pi {
  provider: string;
  model: string;
  thinking: string;

  constructor(provider: string, model: string, thinking: string) {
    this.provider = provider;
    this.model = model;
    this.thinking = thinking;
  }

  // Resolves with the combined pi output; rejects with it attached on failure.
  run(prompt: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = spawn(
        "fence",
        [
          "--settings",
          "fence.json",
          "--",
          "pi",
          "-p",
          prompt,
          "--provider",
          this.provider,
          "--model",
          this.model,
          "--thinking",
          this.thinking,
        ],
        { stdio: ["ignore", "pipe", "pipe"] },
      );

      let output = "";
      child.stdout.on("data", (chunk) => (output += chunk));
      child.stderr.on("data", (chunk) => (output += chunk));
      child.on("error", reject);
      child.on("close", (code) => {
        if (code !== 0) {
          reject(new Error(`pi exited with status ${code}\n\n${output.trimEnd()}`));
        } else resolve(output.trimEnd());
      });
    });
  }
}

// Appends a titled section to the log file.
function logSection(logFile: string, title: string, output: string): void {
  appendFileSync(logFile, `${title}\n\n${output}\n\n---\n\n`);
}

async function main() {
  const implementer = new Pi("anthropic", "claude-sonnet-5-5", "high");

  const directory = process.argv[2]; // kept as given, so paths stay relative to the cwd
  const tasksDir = join(directory, "issues");

  const logFile = join("logs", `${basename(resolve(directory))}.loop.log`);
  mkdirSync("logs", { recursive: true });

  const tasks = readdirSync(tasksDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
    .map((entry) => entry.name)
    .sort();

  for (const name of tasks) {
    const taskFile = join(tasksDir, name);
    // Check current frontmatter only; earlier implementations may change later tasks.
    const frontmatter = readFileSync(taskFile, "utf8").match(
      /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/,
    )?.[1];
    if (!frontmatter || !/^status:[ \t]*ready-for-agent[ \t]*\r?$/m.test(frontmatter)) {
      continue;
    }

    status.set(`Implementing ${taskFile}`);

    const output = await implementer.run(
      `/skill:tdd implement the task described in @${taskFile}. Apply software-design best practices during the implementation. Tick off all completed bullet points in ${taskFile}. Set the task-status to in-review when you're finished. Commit all changes using the commit-message 'Implement ${taskFile}'.`,
    );

    logSection(logFile, `${taskFile} implemented in ${status.stop()}`, output);
  }

  const reviewer = new Pi("anthropic", "claude-opus-5-5", "high");

  const specFile = join(directory, "spec.md");
  
  status.set(`Reviewing ${specFile}`);

  const output = await reviewer.run(`/skill:software-design the last commits implemented the tickets in ${tasksDir}. Please review these commits according to ${specFile}. Pay special attention to correctness and simplicity. Fix found issues right away. If an issue is fully implemented, then please set the status in the issue-file to 'done'. Commit your changes using the commit-message 'Reviewed ${specFile}'.`)

  logSection(logFile, `${specFile} reviewed in ${status.stop()}`, output);
}

main().catch((error) => {
  status.stop();
  console.error(error);
  process.exit(1);
});
