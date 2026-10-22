/**
 * Ntfy Finished Extension
 *
 * Sends a push notification via ntfy.sh when Pi is finished and waiting for input.
 * Topic comes from the NTFY_AGENT_TOPIC environment variable.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	// `agent_settled` fires when Pi will not continue automatically
	// (no retries, compaction, or queued follow-ups pending).
	pi.on("agent_settled", async (_event, ctx) => {
		try {
			const payload = {
				title: `${process.cwd().split("/").pop()}: Agent Finished`,
				topic: process.env.NTFY_AGENT_TOPIC,
				message: ctx.sessionManager.getEntries().filter(e => e.message?.role === "assistant").pop()?.message?.content[0]["text"] || "The agents output",
				tags: ["robot"],
				markdown: true,
				icon: "https://upload.wikimedia.org/wikipedia/commons/8/81/Pi_logo.png",
			};

			await fetch("https://ntfy.sh", {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
				},
				body: JSON.stringify(payload),
			});
		} catch (error) {
			if (ctx.mode === "tui") {
				ctx.ui.notify(`ntfy failed: ${error}`, "error");
			}
		}
	});
}
