/**
 * What Claude Code's Edit/MultiEdit and Codex's apply_patch will write, computed up front so the
 * change can be reviewed before the agent's own tool runs. Each function returns null when the tool
 * itself would fail on the input: then ryno stays out of the way and lets the tool report the error.
 */
import * as path from "node:path";
import { resolvePath } from "../ryno.ts";

const lf = (s: string) => s.replace(/\r\n/g, "\n");

// ───────────────────────────── Claude Code: Edit / MultiEdit ─────────────────────────────

export interface ClaudeEdit {
	old_string: string;
	new_string: string;
	replace_all?: boolean;
}

/** Curly quotes → straight, 1:1 in length, so an index in the normalised text is an index in the original. */
const straightQuotes = (s: string) => s.replace(/[\u2018\u2019]/g, "'").replace(/[\u201C\u201D]/g, '"');

function occurrences(hay: string, needle: string): number {
	let n = 0;
	for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length)) n++;
	return n;
}

/** One Edit against `text` (null = the file does not exist). Mirrors Claude Code's Edit tool. */
export function applyClaudeEdit(text: string | null, e: ClaudeEdit): string | null {
	if (typeof e?.old_string !== "string" || typeof e?.new_string !== "string") return null;
	const oldS = lf(e.old_string), newS = lf(e.new_string);
	if (oldS === newS) return null;
	if (oldS === "") return text === null || text.trim() === "" ? newS : null; // create (or fill an empty file)
	if (text === null) return null;

	let actual = oldS;
	if (!text.includes(oldS)) {
		const i = straightQuotes(text).indexOf(straightQuotes(oldS));
		if (i < 0) return null;
		actual = text.slice(i, i + oldS.length);
	}
	if (!e.replace_all && occurrences(text, actual) > 1) return null;
	// Deleting a whole line also removes its newline.
	if (newS === "" && !actual.endsWith("\n") && text.includes(actual + "\n")) actual += "\n";
	return e.replace_all ? text.split(actual).join(newS) : text.replace(actual, () => newS);
}

/** MultiEdit: each edit applies to the result of the previous one. */
export function applyClaudeEdits(text: string | null, edits: ClaudeEdit[]): string | null {
	if (!Array.isArray(edits) || edits.length === 0) return null;
	let cur = text;
	for (const e of edits) {
		const next = applyClaudeEdit(cur, e);
		if (next === null) return null;
		cur = next;
	}
	return cur === text ? null : cur;
}

// ───────────────────────────── Codex: apply_patch ─────────────────────────────

export interface PatchChunk {
	context?: string; // the `@@ …` line, used to locate the chunk
	oldLines: string[];
	newLines: string[];
	eof: boolean;
}

export type PatchHunk =
	| { type: "add"; path: string; contents: string }
	| { type: "delete"; path: string }
	| { type: "update"; path: string; moveTo?: string; chunks: PatchChunk[] };

/** Parse a `*** Begin Patch … *** End Patch` body (lenient like Codex: heredoc wrappers, stray spaces). */
export function parsePatch(patch: string): PatchHunk[] | null {
	let lines = patch.trim().split("\n").map((l) => l.replace(/\r$/, ""));
	if (lines.length >= 2 && /^<<['"]?\w+['"]?$/.test(lines[0].trim()) && /^\w+$/.test(lines[lines.length - 1].trim())) lines = lines.slice(1, -1);
	if (lines[0]?.trim() !== "*** Begin Patch" || lines[lines.length - 1]?.trim() !== "*** End Patch") return null;
	lines = lines.slice(1, -1);

	const hunks: PatchHunk[] = [];
	let i = 0;
	const header = (l: string, h: string) => (l.trim().startsWith(h) ? l.trim().slice(h.length).trim() : null);
	while (i < lines.length) {
		const line = lines[i];
		let p: string | null;
		if (line.trim() === "" || line.trim().startsWith("*** Environment ID:")) { i++; continue; }
		if ((p = header(line, "*** Add File:")) !== null) {
			i++;
			let contents = "";
			while (i < lines.length && lines[i].startsWith("+")) contents += lines[i++].slice(1) + "\n";
			hunks.push({ type: "add", path: p, contents });
		} else if ((p = header(line, "*** Delete File:")) !== null) {
			i++;
			hunks.push({ type: "delete", path: p });
		} else if ((p = header(line, "*** Update File:")) !== null) {
			i++;
			let moveTo: string | undefined;
			const mv = i < lines.length ? header(lines[i], "*** Move to:") : null;
			if (mv !== null) { moveTo = mv; i++; }
			const chunks: PatchChunk[] = [];
			while (i < lines.length && !(lines[i].startsWith("***") && lines[i].trim() !== "*** End of File")) {
				if (lines[i].trim() === "") { i++; continue; } // blank lines between chunks
				let context: string | undefined;
				if (lines[i].startsWith("@@")) {
					const c = lines[i].slice(2).trim();
					if (c) context = lines[i].slice(lines[i].startsWith("@@ ") ? 3 : 2);
					i++;
				} else if (chunks.length > 0) return null; // only the first chunk may omit its @@ line
				const ch: PatchChunk = { context, oldLines: [], newLines: [], eof: false };
				let n = 0;
				for (; i < lines.length; i++, n++) {
					const l = lines[i];
					if (l.trim() === "*** End of File") { ch.eof = true; i++; break; }
					if (l === "") { ch.oldLines.push(""); ch.newLines.push(""); continue; }
					const tag = l[0], body = l.slice(1);
					if (tag === " ") { ch.oldLines.push(body); ch.newLines.push(body); }
					else if (tag === "-") ch.oldLines.push(body);
					else if (tag === "+") ch.newLines.push(body);
					else break; // next chunk / hunk
				}
				if (n === 0 && !ch.eof) return null;
				chunks.push(ch);
			}
			if (chunks.length === 0) return null;
			hunks.push({ type: "update", path: p, moveTo, chunks });
		} else return null;
	}
	return hunks.length ? hunks : null;
}

const PUNCT: Array<[RegExp, string]> = [
	[/[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/g, "-"],
	[/[\u2018\u2019\u201A\u201B]/g, "'"],
	[/[\u201C\u201D\u201E\u201F]/g, '"'],
	[/[\u00A0\u2002-\u200A\u202F\u205F\u3000]/g, " "],
];
const normPunct = (s: string) => PUNCT.reduce((a, [re, r]) => a.replace(re, r), s.trim());

/** Codex's seek_sequence: exact, then ignoring trailing whitespace, then all surrounding whitespace, then punctuation. */
function seek(lines: string[], pattern: string[], start: number, eof: boolean): number | null {
	if (pattern.length === 0) return start;
	if (pattern.length > lines.length) return null;
	const from = eof ? lines.length - pattern.length : start;
	const tries: Array<(s: string) => string> = [(s) => s, (s) => s.trimEnd(), (s) => s.trim(), normPunct];
	for (const f of tries) {
		for (let i = from; i <= lines.length - pattern.length; i++) {
			let ok = true;
			for (let j = 0; j < pattern.length && ok; j++) ok = f(lines[i + j]) === f(pattern[j]);
			if (ok) return i;
		}
	}
	return null;
}

/** Apply the chunks of one Update hunk to `text` (LF). Mirrors codex-apply-patch. */
export function applyChunks(text: string, chunks: PatchChunk[]): string | null {
	const lines = text.split("\n");
	if (lines[lines.length - 1] === "") lines.pop();
	const repl: Array<[number, number, string[]]> = [];
	let at = 0;
	for (const ch of chunks) {
		if (ch.context !== undefined) {
			const i = seek(lines, [ch.context], at, false);
			if (i === null) return null;
			at = i + 1;
		}
		if (ch.oldLines.length === 0) {
			repl.push([lines.length, 0, ch.newLines]);
			continue;
		}
		let pat = ch.oldLines, neu = ch.newLines;
		let found = seek(lines, pat, at, ch.eof);
		if (found === null && pat[pat.length - 1] === "") {
			pat = pat.slice(0, -1);
			if (neu[neu.length - 1] === "") neu = neu.slice(0, -1);
			found = seek(lines, pat, at, ch.eof);
		}
		if (found === null) return null;
		repl.push([found, pat.length, neu]);
		at = found + pat.length;
	}
	repl.sort((a, b) => a[0] - b[0]);
	for (let k = repl.length - 1; k >= 0; k--) lines.splice(repl[k][0], repl[k][1], ...repl[k][2]);
	if (lines[lines.length - 1] !== "") lines.push("");
	return lines.join("\n");
}

export interface FileChange {
	abs: string; // where the result lands (the destination for a move)
	from?: string; // source path of a move
	original: string | null; // LF text before (of `from` for a move); null = file did not exist
	proposed: string | null; // LF text after; null = deleted
}

/**
 * The net change per file a patch makes. `read` returns LF text or null for a missing file.
 * Returns null when the patch would not apply (Codex will report the error itself).
 */
export function patchChanges(patch: string, cwd: string, read: (abs: string) => string | null): FileChange[] | null {
	const hunks = parsePatch(patch);
	if (!hunks) return null;
	const state = new Map<string, string | null>(); // abs -> current content as the patch proceeds
	const first = new Map<string, string | null>(); // abs -> content before the patch
	const moves = new Map<string, string>(); // dest -> src
	const get = (abs: string) => {
		if (!state.has(abs)) { const t = read(abs); state.set(abs, t); first.set(abs, t); }
		return state.get(abs)!;
	};
	for (const h of hunks) {
		const abs = resolvePath(cwd, h.path);
		if (h.type === "add") { get(abs); state.set(abs, h.contents); continue; }
		const cur = get(abs);
		if (cur === null) return null;
		if (h.type === "delete") { state.set(abs, null); continue; }
		const next = applyChunks(cur, h.chunks);
		if (next === null) return null;
		if (h.moveTo) {
			const dest = resolvePath(cwd, h.moveTo);
			get(dest);
			state.set(abs, null);
			state.set(dest, next);
			moves.set(dest, abs);
		} else state.set(abs, next);
	}
	const out: FileChange[] = [];
	const movedAway = new Set(moves.values());
	for (const [abs, now] of state) {
		const src = moves.get(abs);
		if (src && state.get(src) === null) {
			out.push({ abs, from: src, original: first.get(src) ?? null, proposed: now });
			continue;
		}
		if (movedAway.has(abs) && now === null) continue; // reported with its destination
		if (now !== first.get(abs)) out.push({ abs, original: first.get(abs) ?? null, proposed: now });
	}
	return out;
}

/** `apply_patch <<'EOF' … EOF` sent through the shell tool (optionally after `cd dir &&`). */
export function shellPatch(command: string, cwd: string): { patch: string; cwd: string } | null {
	const m = /^\s*(?:cd\s+(\S+)\s*&&\s*)?(?:apply_patch|applypatch)\s*<<\s*['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\2\s*$/.exec(command);
	if (!m) return null;
	return { patch: m[3], cwd: m[1] ? path.resolve(cwd, m[1].replace(/^['"]|['"]$/g, "")) : cwd };
}
