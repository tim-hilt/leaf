/**
 * Blocks raw `xcodebuild test` calls, so agents run app tests through the
 * Makefile: a failing run otherwise collects diagnostics for ~10 minutes, and
 * the full log floods the context.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

export function runsAppTestsRaw(command: string): boolean {
	return (
		/\bxcodebuild\b[^|;&\n]*\s(test|test-without-building)\b/.test(command) &&
		!/-collect-test-diagnostics\s+never/.test(command)
	);
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (isToolCallEventType("bash", event) && runsAppTestsRaw(event.input.command)) {
			return {
				block: true,
				reason:
					"Run app tests with `make apple-test` (macOS) or `make apple-test-ios` (iOS Simulator), " +
					"narrowed with ONLY=LeafPDFTests/<Suite>[/<test>()]. Full log: /tmp/leafpdf-test.log.",
			};
		}
	});
}
