/**
 * Blocks bash commands that edit files in place (sed -i, perl -i, python
 * writing files, heredocs into files outside /tmp), so agents use the edit
 * and write tools instead: they fail loudly on a mismatch and work the same
 * on macOS and Linux.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

const fileEdits: RegExp[] = [
	/\bsed\b[^|;&\n]*\s(-[a-zA-Z]*i|--in-place)/, // sed -i, sed -Ei, sed --in-place
	/\bperl\b[^|;&\n]*\s-[a-zA-Z]*i/, // perl -pi -e
	/\bpython3?\b[\s\S]*(\.write\(|write_text\()/, // python patch scripts
	/(\bcat|\btee)\s[^|;&\n]*?(>\s*|\s)(?!\/tmp\/|\/dev\/)[\w.~/-]+\s*<<|<<-?\s*'?\w+'?\s*(>\s*|\|\s*tee\s+)(?!\/tmp\/|\/dev\/)[\w.~/-]/, // heredoc into a file
];

export function editsFiles(command: string): boolean {
	return fileEdits.some((pattern) => pattern.test(command));
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (isToolCallEventType("bash", event) && editsFiles(event.input.command)) {
			return {
				block: true,
				reason:
					"Edit files with the edit tool (several edits[] per call) and create them with write. " +
					"bash may only write to /tmp.",
			};
		}
	});
}
