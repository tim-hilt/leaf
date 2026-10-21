/**
 * Ntfy Finished Extension
 *
 * Sends a push notification via ntfy.sh when Pi is finished and waiting for input.
 * Topic comes from the NTFY_AGENT_TOPIC environment variable.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NTFY_URL = `https://ntfy.sh/${process.env.NTFY_AGENT_TOPIC}`;

export default function (pi: ExtensionAPI) {
	// `agent_settled` fires when Pi will not continue automatically
	// (no retries, compaction, or queued follow-ups pending).
	pi.on("agent_settled", async (_event, ctx) => {
		try {
			await fetch(NTFY_URL, {
				method: "POST",
				body: "Agent finished",
			});
		} catch (error) {
			if (ctx.mode === "tui") {
				ctx.ui.notify(`ntfy failed: ${error}`, "error");
			}
		}
	});
}