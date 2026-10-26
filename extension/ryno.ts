/**
 * ryno — editor-side review of agent edits (pi / prime-agent extension)
 *
 * Intercepts `edit` and `write` tool calls, sends the proposed change to a
 * connected editor (nvim / vis) over a unix socket, and waits for the user to
 * accept, reject, or partially accept (per hunk) before the tool runs.
 *
 * Install (symlink or copy):
 *   pi:           ~/.pi/agent/extensions/ryno.ts
 *   prime-agent:  ~/.prime/agent/extensions/ryno.ts
 *
 * Env:
 *   RYNO_NO_EDITOR=allow|block   what to do when no editor is connected (default: allow)
 *   RYNO_DIR=<dir>               discovery dir (default: /tmp/ryno-<uid>)
 *   RYNO_TIMEOUT_MS=<ms>         give up on a review after this long and reject (default: none)
 *
 * Wire protocol (NDJSON, one JSON object per line) — see README.md.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

const PROTOCOL = 1;

// ───────────────────────────── pure helpers ─────────────────────────────

const lf = (s: string) => s.replace(/\r\n/g, "\n");

/** Same normalisation the edit tools use for their fuzzy fallback. */
export function normalizeForFuzzyMatch(text: string): string {
	return text
		.normalize("NFKC")
		.split("\n")
		.map((l) => l.replace(/[\s\uFEFF\u2028\u2029]+$/u, ""))
		.join("\n")
		.replace(/[\u2018\u2019\u201A\u201B]/g, "'")
		.replace(/[\u201C\u201D\u201E\u201F]/g, '"')
		.replace(/[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/g, "-")
		.replace(/[\u00A0\u2002-\u200A\u202F\u205F\u3000]/g, " ");
}

function countOccurrences(hay: string, needle: string): number {
	if (!needle) return 0;
	let n = 0;
	for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length)) n++;
	return n;
}

/**
 * Reproduce what the built-in edit tool will write (mirrors its semantics: every oldText is
 * matched against the ORIGINAL, must be unique and non-overlapping; if any edit needs the fuzzy
 * fallback the whole file is matched in fuzzy-normalised space).
 * Returns null when the tool itself would reject the edit — we then stay out of the way.
 */
export function applyEdits(original: string, edits: Array<{ oldText: string; newText: string }>): string | null {
	if (!Array.isArray(edits) || edits.length === 0) return null;
	const es: Array<{ old: string; text: string }> = [];
	for (const ed of edits) {
		if (typeof ed?.oldText !== "string" || typeof ed?.newText !== "string") return null;
		const old = lf(ed.oldText);
		if (old === "") return null;
		es.push({ old, text: lf(ed.newText) });
	}

	const needsFuzzy = es.some((e) => original.indexOf(e.old) < 0 && normalizeForFuzzyMatch(original).includes(normalizeForFuzzyMatch(e.old)));
	const base = needsFuzzy ? normalizeForFuzzyMatch(original) : original;
	const fbase = needsFuzzy ? base : normalizeForFuzzyMatch(base);

	const spans: Array<{ s: number; e: number; text: string }> = [];
	for (const e of es) {
		let s = base.indexOf(e.old);
		let len = e.old.length;
		if (s < 0) {
			const fo = normalizeForFuzzyMatch(e.old);
			s = fbase.indexOf(fo);
			len = fo.length;
			if (s < 0 || base !== fbase) return null;
		}
		if (countOccurrences(fbase, normalizeForFuzzyMatch(e.old)) > 1) return null;
		spans.push({ s, e: s + len, text: e.text });
	}
	spans.sort((a, b) => a.s - b.s);
	let out = "";
	let pos = 0;
	for (const sp of spans) {
		if (sp.s < pos) return null; // overlap
		out += base.slice(pos, sp.s) + sp.text;
		pos = sp.e;
	}
	out += base.slice(pos);
	return out === base ? null : out;
}

/** Accept the shapes the tools accept: `edits` as a JSON string, and legacy top-level oldText/newText. */
export function normalizeEdits(input: any): Array<{ oldText: string; newText: string }> {
	let edits: any = input?.edits;
	if (typeof edits === "string") {
		try { edits = JSON.parse(edits); } catch { edits = undefined; }
	}
	const out = Array.isArray(edits) ? [...edits] : [];
	if (typeof input?.oldText === "string" && typeof input?.newText === "string") {
		out.push({ oldText: input.oldText, newText: input.newText });
	}
	return out;
}

interface DiskFile {
	text: string; // LF-normalised, BOM stripped
	bom: boolean;
	crlf: boolean;
}

export function readDisk(abs: string): DiskFile | null {
	try {
		let raw = fs.readFileSync(abs, "utf8");
		const bom = raw.charCodeAt(0) === 0xfeff;
		if (bom) raw = raw.slice(1);
		return { text: lf(raw), bom, crlf: raw.includes("\r\n") };
	} catch {
		return null;
	}
}

export function encode(text: string, like: { bom: boolean; crlf: boolean }): string {
	return (like.bom ? "\ufeff" : "") + (like.crlf ? text.replace(/\n/g, "\r\n") : text);
}

export function resolvePath(cwd: string, p: string): string {
	if (p.startsWith("@")) p = p.slice(1);
	if (p === "~" || p.startsWith("~/")) p = path.join(os.homedir(), p.slice(1));
	return path.resolve(cwd, p);
}

function runtimeDir(): string {
	return process.env.RYNO_DIR || path.join("/tmp", `ryno-${process.getuid?.() ?? "u"}`);
}

// ─────────────────── working-tree snapshots (changes made by bash / python) ───────────────────
//
// Commands like `python3 - <<EOF … open(p,'w')` or `sed -i` change files in ways no structured tool
// call describes. For those we snapshot the git-visible working tree before the command, diff after,
// and review what actually changed (applying first, rolling back on rejection).

const MAX_FILE_BYTES = 1 << 20;
const MAX_DIRTY_SNAPSHOT = 2000;
export const MAX_REVIEW_FILES = 20;

export interface Snapshot {
	root: string;
	/** raw content (string), missing (null) or unreviewable (undefined) for files that were dirty at snapshot time */
	before: Map<string, string | null | undefined>;
	dirtyAll: Set<string>;
}

export interface Change {
	abs: string;
	rel: string;
	original: string | null; // raw
	proposed: string | null; // raw; null = deleted
}

/** realpath that tolerates missing files (macOS: /tmp is a symlink to /private/tmp) */
function rp(p: string): string {
	try { return fs.realpathSync(p); } catch { return p; }
}

function git(root: string, args: string[]): string | null {
	const r = spawnSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 256 << 20, timeout: 10000 });
	return r.status === 0 ? r.stdout : null;
}

function readRaw(abs: string): string | null | undefined {
	try {
		const st = fs.statSync(abs);
		if (!st.isFile() || st.size > MAX_FILE_BYTES) return undefined;
		const raw = fs.readFileSync(abs, "utf8");
		return raw.includes("\0") ? undefined : raw;
	} catch (e: any) {
		return e?.code === "ENOENT" || e?.code === "ENOTDIR" ? null : undefined;
	}
}

function indexRaw(root: string, rel: string): string | null | undefined {
	const r = spawnSync("git", ["show", ":" + rel], { cwd: root, encoding: "utf8", maxBuffer: 64 << 20, timeout: 5000 });
	if (r.status !== 0) return null; // not in the index: an untracked file
	return r.stdout.includes("\0") || r.stdout.length > MAX_FILE_BYTES ? undefined : r.stdout;
}

function dirtyList(root: string): string[] | null {
	const out = git(root, ["ls-files", "-z", "-m", "-o", "--exclude-standard"]);
	return out === null ? null : [...new Set(out.split("\0").filter(Boolean))];
}

export function takeSnapshot(cwd: string): Snapshot | null {
	const root = git(cwd, ["rev-parse", "--show-toplevel"])?.trim();
	if (!root) return null;
	const list = dirtyList(root);
	if (!list) return null;
	const before = new Map<string, string | null | undefined>();
	for (const rel of list.slice(0, MAX_DIRTY_SNAPSHOT)) before.set(rel, readRaw(path.join(root, rel)));
	return { root, before, dirtyAll: new Set(list) };
}

/** Files whose content differs from the snapshot. `approved` = abs path -> LF content already reviewed. */
export function changesSince(snap: Snapshot, approved?: Map<string, string>): { changes: Change[]; skipped: number } {
	const now = dirtyList(snap.root) ?? [];
	const approvedReal = new Map([...(approved ?? [])].map(([k, v]) => [rp(k), v]));
	const changes: Change[] = [];
	let skipped = 0;
	for (const rel of new Set([...snap.dirtyAll, ...now])) {
		const abs = path.join(snap.root, rel);
		const nw = readRaw(abs);
		let old: string | null | undefined;
		if (snap.before.has(rel)) old = snap.before.get(rel);
		else if (snap.dirtyAll.has(rel)) old = undefined; // was dirty but beyond the snapshot cap
		else old = indexRaw(snap.root, rel);
		if (nw === undefined || old === undefined) { if (nw !== old) skipped++; continue; }
		if (nw === old) continue;
		if (nw !== null && approvedReal.get(rp(abs)) === lf(nw.replace(/^\ufeff/, ""))) continue; // reviewed already
		changes.push({ abs, rel, original: old, proposed: nw });
	}
	return { changes, skipped };
}

// ───────────────────────────── bash policy ─────────────────────────────
//
//   review  bash may change files; each change is applied, then reviewed in the editor (reject = roll back)
//   block   bash may NOT change project files: writes are denied up front where possible (macOS
//           sandbox-exec), anything that still changed is reverted, and the agent is told to use the
//           edit/write tools — which are reviewed *before* they apply
//   off     ryno ignores bash
//
// Source: RYNO_BASH env, else ~/.config/ryno/settings.json {"bash": "..."}, else "review".

export type BashMode = "review" | "block" | "off";
const BASH_MODES: BashMode[] = ["review", "block", "off"];

export function settingsPath(): string {
	return process.env.RYNO_SETTINGS ?? path.join(os.homedir(), ".config", "ryno", "settings.json");
}

export function loadBashMode(): BashMode {
	const env = process.env.RYNO_BASH as BashMode | undefined;
	if (env && BASH_MODES.includes(env)) return env;
	try {
		const s = JSON.parse(fs.readFileSync(settingsPath(), "utf8"));
		if (BASH_MODES.includes(s?.bash)) return s.bash;
	} catch {}
	return "review";
}

export const BLOCK_PROMPT =
	"File-change policy (enforced): do NOT create, modify or delete project files from bash or python " +
	"(no heredoc rewrites, `sed -i`, `open(…, 'w')`, `>` redirects, `mv`/`rm` of project files, formatters that rewrite files). " +
	"Shell commands run with project files read-only and any file changes they make are reverted. " +
	"Make every file change with the edit tool (or write for new files): the user reviews those in their editor before they apply.";

const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
const MAX_SANDBOX_FILES = 4000; // the profile compiler gives up somewhere between 5k and 10k rules
let sandboxWorks: boolean | undefined;

function canSandbox(): boolean {
	if (process.env.RYNO_SANDBOX === "off") return false;
	if (sandboxWorks === undefined) {
		sandboxWorks =
			process.platform === "darwin" &&
			fs.existsSync(SANDBOX_EXEC) &&
			spawnSync(SANDBOX_EXEC, ["-p", "(version 1)(allow default)", "/usr/bin/true"], { timeout: 5000 }).status === 0; // fails when already sandboxed
	}
	return sandboxWorks;
}

const shq = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";
const sbq = (s: string) => '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';

/**
 * Wrap a bash command so it cannot write any file git knows about (tracked + untracked, not ignored).
 * Ignored paths (build caches, outputs) stay writable, so builds and tests still work.
 */
export function sandboxCommand(command: string, root: string, profilePath: string): string | null {
	if (!canSandbox()) return null;
	const out = git(root, ["ls-files", "-z", "-c", "-o", "--exclude-standard"]);
	if (out === null) return null;
	const files = [...new Set(out.split("\0").filter(Boolean))];
	if (files.length === 0 || files.length > MAX_SANDBOX_FILES) return null;
	const real = rp(root);
	// Sandboxed processes may not exec setuid programs at all; let the read-only ones run unsandboxed.
	const setuidOk = ["/bin/ps", "/usr/bin/top"].filter((f) => fs.existsSync(f)).map((f) => `(literal ${sbq(f)})`).join(" ");
	const profile = `(version 1)\n(allow default)\n(allow process-exec (with no-sandbox) ${setuidOk})\n(deny file-write*\n${files.map((f) => `  (literal ${sbq(path.join(real, f))})`).join("\n")})\n`;
	fs.writeFileSync(profilePath, profile, { mode: 0o600 });
	return `${SANDBOX_EXEC} -f ${shq(profilePath)} bash -c ${shq(command)}`;
}

/** Undo changes: restore previous content, delete files that did not exist before. */
export function revertChanges(changes: Change[]): { reverted: string[]; failed: string[] } {
	const reverted: string[] = [], failed: string[] = [];
	for (const c of changes) {
		try {
			if (c.original === null) fs.unlinkSync(c.abs);
			else fs.writeFileSync(c.abs, c.original);
			reverted.push(c.original === null ? `${c.rel} (new file, deleted)` : c.rel);
		} catch (err: any) {
			failed.push(`${c.rel} (${err?.message ?? err})`);
		}
	}
	return { reverted, failed };
}

export function blockNote(reverted: string[], failed: string[], skipped: number, sawEperm: boolean): string | null {
	const parts: string[] = [];
	if (sawEperm) parts.push("The \"Operation not permitted\" errors above are expected: project files are read-only for shell commands in this session.");
	if (reverted.length) parts.push(`File changes made by the command were REVERTED: ${reverted.join(", ")}.`);
	if (failed.length) parts.push(`Could not revert: ${failed.join(", ")}.`);
	if (skipped) parts.push(`${skipped} changed file(s) could not be checked (binary or larger than 1 MB).`);
	if (!parts.length) return null;
	return `[ryno] ${parts.join(" ")} Make file changes with the edit/write tools instead; the user reviews them in their editor before they apply.`;
}

// ───────────────────────────── extension ─────────────────────────────

type Decision = {
	type: "decision";
	id: string;
	action: "accept" | "reject" | "partial";
	content?: string;
	reason?: string;
	accepted?: number;
	total?: number;
	rejected?: Array<{ line: number; old: string; new: string; comment?: string }>;
};

type SystemReject = { action: "reject"; reason: string; system: true }; // timeout, abort, disconnect — not a user choice

/** What an editor tells us about itself, so reviews go to the right one of several. */
interface EditorState {
	files: Set<string>; // real paths of its loaded buffers
	cwd?: string;
	linked?: boolean; // the user explicitly linked this editor to this session (:RynoLink)
	lastActive: number; // when we last heard the user doing something in it (our clock)
}

interface Pending {
	targets?: Set<net.Socket>; // editors this review was sent to (undefined = all)
	msg: Record<string, unknown>;
	resolve: (d: Decision | SystemReject) => void;
	timer?: ReturnType<typeof setTimeout>;
}

export default function ryno(pi: ExtensionAPI) {
	const dir = runtimeDir();
	const sockPath = path.join(dir, `${process.pid}.sock`);
	const descPath = path.join(dir, `${process.pid}.json`);
	const clients = new Set<net.Socket>();
	const editors = new Map<net.Socket, EditorState>();
	const pending = new Map<string, Pending>();
	const bashSnapshots = new Map<string, { snap: Snapshot | null; profile?: string; sandboxed: boolean; mode: BashMode }>();
	let bashMode: BashMode = loadBashMode();
	let server: net.Server | null = null;
	let info = { cwd: process.cwd(), sessionId: "" };
	let uiRef: any = null;
	const startedAt = Date.now();

	const dbg = (...a: unknown[]) => {
		if (process.env.RYNO_DEBUG) fs.appendFileSync("/tmp/ryno-debug.log", `${new Date().toISOString()} [${process.pid}] ${a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")}\n`);
	};


	// ── socket plumbing ──

	const send = (sock: net.Socket, msg: unknown) => {
		if (!sock.destroyed) sock.write(JSON.stringify(msg) + "\n");
	};
	const broadcast = (msg: unknown) => clients.forEach((c) => send(c, msg));
	const realOrSelf = (p: string) => {
		try { return fs.realpathSync(p); } catch {}
		try { return path.join(fs.realpathSync(path.dirname(p)), path.basename(p)); } catch {}
		return p;
	};
	/**
	 * Pick which connected editors should see a review of `file`, best tier first:
	 *   3 = manually linked to this session (:RynoLink), 2 = has the file open, 1 = its cwd contains the file (deepest cwd wins), 0 = neither.
	 * Within a tier the editor the user touched most recently wins. Editors that never reported
	 * state (vis, old plugins) tie at the bottom, so with no information we ask everyone. Ties among reporting editors pick one.
	 */
	function pickEditors(file: unknown, candidates: Iterable<net.Socket> = clients): Set<net.Socket> {
		const real = typeof file === "string" ? realOrSelf(file) : "";
		const ranked = [...candidates].map((s) => {
			const st = editors.get(s);
			const cwd = st?.cwd ? realOrSelf(st.cwd).replace(/\/+$/, "") : "";
			const inCwd = !!real && !!cwd && real.startsWith(cwd + "/");
			const has = st?.linked ? 3 : st && real && st.files.has(real) ? 2 : inCwd ? 1 : 0;
			return { s, has, depth: has === 1 ? cwd.length : 0, active: st?.lastActive ?? 0 };
		});
		ranked.sort((a, b) => b.has - a.has || b.depth - a.depth || b.active - a.active);
		const top = ranked[0];
		if (!top) return new Set();
		const tied = ranked.filter((r) => r.has === top.has && r.depth === top.depth && r.active === top.active).map((r) => r.s);
		// A genuine tie between editors that reported state: pick one (earliest connected) rather than
		// opening the review everywhere. Editors that reported nothing can't be told apart: ask them all.
		return new Set(editors.has(tied[0]) ? tied.slice(0, 1) : tied);
	}
	function route(p: Pending) {
		p.targets = pickEditors(p.msg.path);
		dbg("route", p.msg.path, "->", p.targets.size, "of", clients.size, "editors");
		p.targets.forEach((s) => send(s, p.msg));
	}
	const hello = () => ({
		type: "hello",
		protocol: PROTOCOL,
		pid: process.pid,
		cwd: info.cwd,
		sessionId: info.sessionId,
		agent: process.env.RYNO_AGENT ?? "pi",
	});

	const updateStatus = () => {
		try {
			const parts = [];
			if (clients.size) parts.push(`${clients.size} editor${clients.size > 1 ? "s" : ""}`);
			if (bashMode === "block") parts.push("bash read-only");
			uiRef?.setStatus?.("ryno", parts.length ? `ryno: ${parts.join(" · ")}` : undefined);
		} catch {}
	};

	function settle(id: string, d: Parameters<Pending["resolve"]>[0]) {
		const p = pending.get(id);
		if (!p) return;
		pending.delete(id);
		if (p.timer) clearTimeout(p.timer);
		p.resolve(d);
		broadcast({ type: "resolved", id }); // lets other editors drop the review
	}

	function writeDescriptor() {
		fs.writeFileSync(descPath, JSON.stringify({ ...hello(), socket: sockPath, startedAt: startedAt }), { mode: 0o600 });
	}

	function pruneStale() {
		for (const f of fs.readdirSync(dir)) {
			const m = /^(\d+)\.(json|sock)$/.exec(f);
			if (!m) continue;
			try {
				process.kill(Number(m[1]), 0);
			} catch {
				try { fs.unlinkSync(path.join(dir, f)); } catch {}
			}
		}
	}

	function start() {
		if (server) return;
		fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
		try { fs.chmodSync(dir, 0o700); } catch {}
		pruneStale();
		try { fs.unlinkSync(sockPath); } catch {}

		server = net.createServer((sock) => {
			clients.add(sock);
			dbg("client connected; total", clients.size);
			send(sock, hello());
			for (const p of pending.values()) if (!p.targets?.size) send(sock, p.msg); // late joiner: only reviews nobody has
			updateStatus();

			let buf = "";
			sock.setEncoding("utf8");
			sock.on("data", (chunk: string) => {
				buf += chunk;
				let nl: number;
				while ((nl = buf.indexOf("\n")) >= 0) {
					const line = buf.slice(0, nl);
					buf = buf.slice(nl + 1);
					if (!line.trim()) continue;
					try {
						const m = JSON.parse(line);
						if (m?.type === "decision" && typeof m.id === "string") settle(m.id, m as Decision);
						else if (m?.type === "editor") {
							const st = editors.get(sock) ?? { files: new Set<string>(), lastActive: 0 };
							if (Array.isArray(m.files)) st.files = new Set(m.files.filter((f: unknown) => typeof f === "string"));
							if (typeof m.cwd === "string") st.cwd = m.cwd;
							st.linked = m.linked === true;
							if (m.active) st.lastActive = Date.now();
							editors.set(sock, st);
						}
					} catch {}
				}
			});
			const gone = () => {
				if (!clients.delete(sock)) return;
				editors.delete(sock);
				dbg("client gone; total", clients.size);
				updateStatus();
				if (clients.size === 0) {
					// Nobody left to answer: fail safe instead of hanging the agent forever.
					for (const id of [...pending.keys()]) settle(id, { action: "reject", reason: "editor disconnected during review", system: true });
				} else {
					// Reviews whose editors are all gone move to the best remaining one.
					for (const p of pending.values()) {
						if (!p.targets?.has(sock)) continue;
						p.targets.delete(sock);
						if (p.targets.size === 0) route(p);
					}
				}
			};
			sock.on("close", gone);
			sock.on("error", gone);
		});
		server.on("error", () => {});
		server.listen(sockPath, () => {
			try { fs.chmodSync(sockPath, 0o600); } catch {}
			writeDescriptor();
		});
	}

	function stop() {
		for (const id of [...pending.keys()]) settle(id, { action: "reject", reason: "agent session ended", system: true });
		clients.forEach((c) => c.destroy());
		clients.clear();
		editors.clear();
		server?.close();
		server = null;
		for (const f of [sockPath, descPath]) try { fs.unlinkSync(f); } catch {}
	}
	process.on("exit", () => { for (const f of [sockPath, descPath]) try { fs.unlinkSync(f); } catch {} });

	pi.on("session_start", async (_e: any, ctx: any) => {
		uiRef = ctx.ui;
		bashMode = loadBashMode();
		info = { cwd: ctx.cwd, sessionId: safe(() => ctx.sessionManager.getSessionId()) ?? "" };
		start();
		if (server?.listening) writeDescriptor();
		updateStatus();
	});

	// pi may build a *fresh* extension instance for /new, /resume, /fork and /reload, so this instance
	// must not outlive its session: an orphaned server keeps editors attached to a handler nobody runs.
	pi.on("before_agent_start", async (event: any) => {
		if (bashMode !== "block" || typeof event?.systemPrompt !== "string") return;
		return { systemPrompt: event.systemPrompt + "\n\n" + BLOCK_PROMPT };
	});

	pi.registerCommand?.("ryno-bash", {
		description: "ryno: how bash may change files — review | block | off (this session)",
		handler: async (args: string, ctx: any) => {
			const a = (args ?? "").trim() as BashMode;
			if (BASH_MODES.includes(a)) bashMode = a;
			else if (a) return ctx.ui.notify(`ryno: unknown mode "${a}" (review | block | off)`, "error");
			updateStatus();
			ctx.ui.notify(
				`ryno bash mode: ${bashMode}` +
					(bashMode === "block" ? (canSandbox() ? " (sandboxed: project files read-only)" : " (no sandbox here: changes are reverted after the command)") : "") +
					`. Default comes from ${settingsPath()} or RYNO_BASH.`,
				"info",
			);
		},
	});

	pi.on("session_shutdown", async () => {
		stop();
	});

	// Belt and braces: if a previous instance in this process was never told to shut down, evict it.
	const g = globalThis as any;
	try { g.__rynoStop?.(); } catch {}
	g.__rynoStop = stop;

	/** Send a review to the connected editors and wait for the first answer. */
	function askEditor(msg: { id: string } & Record<string, unknown>, opts: { signal?: AbortSignal; timeoutMs?: number } = {}) {
		const id = msg.id;
		return new Promise<Decision | SystemReject>((resolve) => {
			const p: Pending = { msg, resolve };
			pending.set(id, p);
			opts.signal?.addEventListener("abort", () => settle(id, { action: "reject", reason: "aborted", system: true }), { once: true });
			route(p);
			const ms = Number(opts.timeoutMs ?? process.env.RYNO_TIMEOUT_MS);
			if (ms > 0) {
				const t = setTimeout(
					() => settle(id, { action: "reject", reason: `no answer from the editor within ${Math.round(ms / 1000)}s; ask the user to review it again`, system: true }),
					ms,
				);
				t.unref?.();
				pending.get(id)!.timer = t;
			}
		});
	}

	/**
	 * Review changes a command has ALREADY made to disk. Accept keeps them; reject restores the
	 * previous content (or deletes a file the command created); partial writes the accepted hunks.
	 * Answers that are not a user choice (editor gone, timeout) keep the changes.
	 */
	async function reviewChanges(changes: Change[], cwd: string, label: string, timeoutMs?: number) {
		const kept: string[] = [], rolledBack: string[] = [], partial: string[] = [], unreviewed: string[] = [];
		for (const c of changes) {
			const strip = (t: string) => lf(t.replace(/^\ufeff/, ""));
			const rel = c.rel;
			const id = randomUUID();
			const d = await askEditor(
				{
					type: "review", id, tool: label, path: c.abs, relpath: path.relative(rp(cwd), c.abs) || rel,
					isNew: c.original === null, deleted: c.proposed === null, post: true,
					original: c.original === null ? null : strip(c.original),
					proposed: c.proposed === null ? "" : strip(c.proposed),
				},
				{ timeoutMs },
			);
			const like = { bom: !!c.original?.startsWith("\ufeff"), crlf: !!c.original?.includes("\r\n") };
			try {
				if ("system" in d || d.action === "accept") {
					("system" in d ? unreviewed : kept).push(rel);
				} else if (d.action === "partial" && typeof d.content === "string" && c.original !== null) {
					fs.writeFileSync(c.abs, encode(d.content, like));
					partial.push(`${rel} (${d.accepted ?? "some"} of ${d.total ?? "its"} hunks kept${d.rejected?.length ? "; " + describeRejected(d.rejected).replace(/\n/g, " ") : ""})`);
				} else if (c.original === null) {
					fs.unlinkSync(c.abs);
					rolledBack.push(`${rel} (new file deleted)`);
				} else {
					fs.writeFileSync(c.abs, c.original);
					rolledBack.push(rel);
				}
			} catch (err: any) {
				unreviewed.push(`${rel} (could not apply the decision: ${err?.message ?? err})`);
			}
			broadcast({ type: "applied", id, path: c.abs, ok: true });
		}
		const lines: string[] = [];
		if (kept.length) lines.push(`kept: ${kept.join(", ")}`);
		if (rolledBack.length) lines.push(`ROLLED BACK (restored to the content before your command): ${rolledBack.join(", ")}`);
		if (partial.length) lines.push(`PARTIALLY kept: ${partial.join("; ")}`);
		if (unreviewed.length) lines.push(`not reviewed (editor unavailable): ${unreviewed.join(", ")}`);
		const needsAttention = rolledBack.length > 0 || partial.length > 0;
		const text =
			`[ryno] The user reviewed the file changes your command made in their editor — ${lines.join("; ")}.` +
			(needsAttention ? " Output above (e.g. build/test results) may reflect the rolled-back state. Do not redo rolled-back changes unless asked; re-read files before editing them again." : "");
		return { kept, rolledBack, partial, unreviewed, needsAttention, text };
	}

	(globalThis as any).__rynoApi = { hasEditors: () => clients.size > 0, reviewChanges, bashMode: () => bashMode };

	// ── the interception ──

	pi.on("tool_call", async (event: any, ctx: any) => {
		dbg("tool_call", event.toolName, "editors:", clients.size, "input:", event.input);
		if (event.toolName === "bash") {
			const mode = bashMode;
			if (mode === "off" || typeof event.input?.command !== "string") return;
			if (mode === "review" && clients.size === 0) return; // nobody to review with
			const snap = takeSnapshot(ctx.cwd);
			let profile: string | undefined;
			let sandboxed = false;
			if (mode === "block" && snap) {
				profile = path.join(dir, `sb-${process.pid}-${String(event.toolCallId).replace(/[^\w-]/g, "_")}.sb`);
				const wrapped = sandboxCommand(event.input.command, snap.root, profile);
				if (wrapped) {
					event.input.command = wrapped; // documented: tool_call may mutate the input in place
					sandboxed = true;
				} else profile = undefined;
			}
			bashSnapshots.set(event.toolCallId, { snap, profile, sandboxed, mode });
			dbg("bash", mode, snap ? `snapshot ${snap.dirtyAll.size} dirty @ ${snap.root}` : "no snapshot (not a git repo?)", sandboxed ? "sandboxed" : "");
			return;
		}
		if (event.toolName !== "edit" && event.toolName !== "write") return;
		const input = event.input as any;
		if (typeof input?.path !== "string") return void dbg("skip: no string path");

		const abs = resolvePath(ctx.cwd, input.path);
		const disk = readDisk(abs);

		let original: string | null;
		let proposed: string;
		if (event.toolName === "edit") {
			if (!disk) return void dbg("skip: cannot read", abs); // tool will fail on its own
			const p = applyEdits(disk.text, normalizeEdits(input));
			if (p === null) return void dbg("skip: edits not reproducible against", abs); // don't second-guess the tool
			original = disk.text;
			proposed = p;
		} else {
			if (typeof input.content !== "string") return;
			original = disk ? disk.text : null;
			proposed = lf(input.content);
		}
		if (original === proposed) return void dbg("skip: no-op"); // no-op

		if (clients.size === 0) {
			dbg("skip: no editor connected");
			if ((process.env.RYNO_NO_EDITOR ?? "allow") === "block") {
				return { block: true, reason: "ryno: no editor connected to review this change (RYNO_NO_EDITOR=block)" };
			}
			return;
		}

		const id: string = event.toolCallId;
		const msg = {
			type: "review",
			id,
			tool: event.toolLabel ?? event.toolName, // adapters may relabel (e.g. an edit found inside a REPL cell)
			path: abs,
			relpath: path.relative(ctx.cwd, abs),
			isNew: original === null,
			original,
			proposed,
		};

		const decision = await askEditor(msg, { signal: ctx.signal, timeoutMs: event.timeoutMs });

		const rel = msg.relpath;
		if (decision.action === "accept") return;

		if (decision.action === "partial" && typeof (decision as Decision).content === "string" && disk) {
			const d = decision as Decision;
			try {
				fs.writeFileSync(abs, encode(d.content!, disk));
				broadcast({ type: "applied", id, path: abs, ok: true });
			} catch (err: any) {
				return { block: true, reason: `ryno: user accepted a subset of the edit but writing ${rel} failed: ${err?.message ?? err}` };
			}
			return {
				block: true,
				reason:
					`The user reviewed your change to ${rel} and accepted only ${d.accepted ?? "some"} of ${d.total ?? "its"} hunks. ` +
					`The accepted hunks HAVE been written to disk; the rejected ones were not. ` +
					describeRejected(d.rejected) +
					`Do not re-apply the rejected hunks unless asked. Re-read the file before further edits to it.` +
					(d.reason ? ` User note: ${d.reason}` : ""),
			};
		}

		const why = (decision as any).reason ? ` Reason: ${(decision as any).reason}` : "";
		const rejected = describeRejected((decision as Decision).rejected);
		return { block: true, reason: `The user rejected this change to ${rel} in their editor. Nothing was written.${why}${rejected ? `\n${rejected}` : ""} Ask what they want instead of retrying the same change.` };
	});

	// Tell editors when an accepted change landed, so they can reload the buffer.
	pi.on("tool_result", async (event: any) => {
		if (event.toolName === "bash") {
			const st = bashSnapshots.get(event.toolCallId);
			bashSnapshots.delete(event.toolCallId);
			if (!st) return;
			if (st.profile) try { fs.unlinkSync(st.profile); } catch {}
			if (!st.snap) return;
			const { changes, skipped } = changesSince(st.snap);
			dbg("bash changes", changes.map((c) => c.rel), "skipped", skipped);
			const out = (event.content ?? []).map((c: any) => c?.text ?? "").join("\n");

			if (st.mode === "block") {
				// With the sandbox, known files could not have been written by the command: a change there is
				// someone else's (the user saving in the editor) and must not be reverted. Only new files are.
				const toRevert = st.sandboxed ? changes.filter((c) => c.original === null) : changes;
				const { reverted, failed } = revertChanges(toRevert);
				for (const c of toRevert) broadcast({ type: "applied", id: randomUUID(), path: c.abs, ok: true });
				const note = blockNote(reverted, failed, skipped, st.sandboxed && /Operation not permitted/.test(out));
				return note ? { content: [...(event.content ?? []), { type: "text", text: note }] } : undefined;
			}

			if (changes.length === 0 || clients.size === 0) return;
			if (changes.length > MAX_REVIEW_FILES) {
				return { content: [...(event.content ?? []), { type: "text", text: `[ryno] ${changes.length} files changed; too many to review in the editor, so none were.` }] };
			}
			const r = await reviewChanges(changes, info.cwd, "bash");
			return { content: [...(event.content ?? []), { type: "text", text: r.text }] };
		}
		if (event.toolName !== "edit" && event.toolName !== "write") return;
		const p = (event.input as any)?.path;
		if (typeof p !== "string") return;
		broadcast({ type: "applied", id: event.toolCallId, path: resolvePath(info.cwd, p), ok: !event.isError });
	});
}

function describeRejected(r: Decision["rejected"]): string {
	if (!Array.isArray(r) || r.length === 0) return "";
	const clip = (s: string) => (s.length > 300 ? s.slice(0, 300) + "…" : s);
	const items = r.slice(0, 10).map(
		(h) => `  - near line ${h.line}: wanted to replace ${JSON.stringify(clip(h.old))} with ${JSON.stringify(clip(h.new))}${h.comment ? ` — User comment: ${h.comment}` : ""}`,
	);
	return `Rejected hunks:\n${items.join("\n")}\n` + (r.length > 10 ? `  (+${r.length - 10} more)\n` : "");
}

function safe<T>(f: () => T): T | undefined {
	try { return f(); } catch { return undefined; }
}
