/**
 * Ntfy Finished Extension
 *
 * Sends a push notification via ntfy.sh when Pi is finished and waiting for input.
 * Topic comes from the NTFY_AGENT_TOPIC environment variable.
 */

import { basename } from "node:path";
import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";

// ntfy rejects messages above 4096 bytes; stay well below.
const MAX_MESSAGE_CHARS = 1000;

export default function (pi: ExtensionAPI) {
	// `agent_settled` fires when Pi will not continue automatically
	// (no retries, compaction, or queued follow-ups pending).
	pi.on("agent_settled", async (_event, ctx) => {
		const topic = process.env.NTFY_AGENT_TOPIC;
		if (!topic) return;

		try {
			const payload = {
				title: `${basename(ctx.cwd)}: Agent Finished`,
				topic,
				message: lastAssistantText(ctx.sessionManager.getBranch()) ?? "The agent finished.",
				tags: ["robot"],
				markdown: true,
				icon: "https://upload.wikimedia.org/wikipedia/commons/8/81/Pi_logo.png",
			};

			const res = await fetch("https://ntfy.sh", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(payload),
			});
			if (!res.ok) throw new Error(`HTTP ${res.status}`);
		} catch (error) {
			if (ctx.mode === "tui") {
				ctx.ui.notify(`ntfy failed: ${error}`, "error");
			}
		}
	});
}

/** Text of the last assistant message on the current branch, truncated. */
function lastAssistantText(entries: SessionEntry[]): string | undefined {
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		const message = entry.type === "message" ? entry.message : undefined;
		if (message?.role !== "assistant") continue;
		const content = message.content;
		const text = (typeof content === "string"
			? content
			: content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n")
		).trim();
		if (text) {
			return text.length > MAX_MESSAGE_CHARS ? `${text.slice(0, MAX_MESSAGE_CHARS)}…` : text;
		}
	}
	return undefined;
}
