/**
 * ryno adapter for the Rust prime-agent (native extension protocol v3).
 *
 * prime-agent talks JSON-RPC 2.0 over stdio to a long-lived extension process and asks it
 * (`tool/beforeCall`) before every model tool call. This shim exposes that to the very same
 * core used by the pi extension (../ryno.ts) through a tiny pi-shaped `on()` API, so both
 * agents behave identically and speak the same editor protocol.
 *
 * Runs on Node >= 23.6 (native TypeScript stripping) or bun.
 */
import ryno, { BLOCK_PROMPT, MAX_REVIEW_FILES, blockNote, changesSince, encode, readDisk, revertChanges, takeSnapshot, type BashMode, type Snapshot } from "../ryno.ts";
import { extractEditCalls, simulate } from "./pyedits.ts";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import * as readline from "node:readline";

// The host cancels a gate after toolGate.timeoutMs (max 60 s): answer a bit earlier, with a useful reason.
process.env.RYNO_TIMEOUT_MS ??= "55000";
process.env.RYNO_AGENT ??= "prime-agent";

const handlers: Record<string, (e: any, c: any) => Promise<any> | any> = {};
ryno({ on: (name: string, h: any) => void (handlers[name] = h) } as any);

let cwd = process.cwd();
let nextId = 1;
const write = (m: unknown) => process.stdout.write(JSON.stringify(m) + "\n");
const reply = (id: unknown, result: unknown) => write({ jsonrpc: "2.0", id, result });
const fail = (id: unknown, code: number, message: string) => write({ jsonrpc: "2.0", id, error: { code, message } });
const hostRequest = (method: string, params: unknown) => write({ jsonrpc: "2.0", id: nextId++, method, params }); // answers are ignored

const ctx = () => ({
	cwd,
	signal: undefined,
	ui: {
		setStatus: (_key: string, text?: string) => hostRequest("status/set", { text: text ? text.slice(0, 60) : null }),
	},
	sessionManager: { getSessionId: () => "" },
});

// Calls we let through, keyed by tool+args, so that `tool_execution_end` (which carries the args
// thanks to the `transcript` permission) can tell editors which files changed and review whatever
// else the command did to the working tree.
interface Inflight {
	files: Array<{ id: string; path: string }>;
	snap?: Snapshot | null;
	approved?: Map<string, string>; // abs path -> LF content the user already approved before the call
}
const allowed = new Map<string, Inflight[]>();
const callKey = (tool: string, args: unknown) => tool + "\0" + JSON.stringify(args);
const remember = (tool: string, args: unknown, e: Inflight) => {
	const k = callKey(tool, args);
	allowed.set(k, [...(allowed.get(k) ?? []), e]);
};

// ── post-hoc review of what a command actually changed (python/bash write files in ways no gate can see)
const api = () =>
	(globalThis as any).__rynoApi as
		| { hasEditors(): boolean; bashMode(): BashMode; reviewChanges(c: any, cwd: string, label: string): Promise<{ needsAttention: boolean; text: string }> }
		| undefined;
const mode = (): BashMode => api()?.bashMode() ?? "review";
let postWork: Promise<unknown> = Promise.resolve();
let postBusy = 0;
let undelivered: string | null = null; // outcome the agent has not been told about yet
let agentRunning = false;

function schedulePost(job: () => Promise<void>) {
	postBusy++;
	postWork = postWork.then(job).catch((err) => console.error("ryno: post review failed:", err)).finally(() => void postBusy--);
}

function deliver(text: string) {
	if (agentRunning) undelivered = undelivered ? undelivered + "\n" + text : text; // the next gate call carries it
	else hostRequest("session/sendMessage", { text, deliverAs: "followUp" }); // turn already over
}

async function reviewAfter(tool: string, e: Inflight) {
	if (!e.snap) return;
	if (mode() === "block") {
		// edits the user approved up front stay; everything else the command changed is undone
		const { changes, skipped } = changesSince(e.snap, e.approved);
		const { reverted, failed } = revertChanges(changes);
		for (const c of changes) await handlers.tool_result?.({ toolName: "write", toolCallId: randomUUID(), input: { path: c.abs }, isError: false }, ctx());
		const note = blockNote(reverted, failed, skipped, false);
		if (note) deliver(note.replace("[ryno] ", `[ryno] (your previous ${tool} call) `));
		return;
	}
	if (!api()?.hasEditors()) return;
	const { changes } = changesSince(e.snap, e.approved);
	if (changes.length === 0) return;
	if (changes.length > MAX_REVIEW_FILES) {
		undelivered = `[ryno] Your ${tool} call changed ${changes.length} files; too many to review in the editor, so none were.`;
		return;
	}
	const r = await api()!.reviewChanges(changes, cwd, tool);
	if (r.needsAttention) deliver(r.text);
}

const GATE_BUDGET_MS = Number(process.env.RYNO_TIMEOUT_MS) || 55000;

/**
 * prime-agent's model edits files with `await edit(path=…, old_str=…, new_str=…)` inside an `ipython`
 * cell, so the gate only sees Python source. Extract the edits we can resolve statically, ask the
 * editor about each changed file, and block the whole cell if anything was declined.
 */
async function gateIpython(code: string): Promise<{ block: true; reason: string } | { reviewed: Array<{ id: string; path: string }>; approved: Map<string, string> } | undefined> {
	const calls = extractEditCalls(code);
	if (!calls || calls.length === 0) return;
	if (mode() === "block" && calls.some((c) => "unresolved" in c)) {
		return {
			block: true,
			reason:
				"[ryno] This cell was NOT run: it calls edit() with arguments that can only be known at runtime " +
				"(computed strings, or inside a loop/if/function), so the user could not review the change before it applies. " +
				"Call edit() at the top level of a cell with literal strings (or variables assigned from literals, e.g. old = '''...''').",
		};
	}
	const { changes, complete } = simulate(calls, cwd);
	if (!complete) console.error("ryno: some edit() calls in this cell are dynamic or would fail; only the leading ones are reviewed");
	if (changes.length === 0) return;

	const started = Date.now();
	const outcomes: Array<{ rel: string; result: any; change: (typeof changes)[number]; id: string }> = [];
	for (const change of changes) {
		const id = randomUUID();
		const left = Math.max(1000, GATE_BUDGET_MS - (Date.now() - started));
		const result = await handlers.tool_call?.(
			{ toolName: "write", toolLabel: "edit", toolCallId: id, timeoutMs: left, input: { path: change.abs, content: change.final } },
			ctx(),
		);
		outcomes.push({ rel: path.relative(cwd, change.abs) || change.abs, result, change, id });
		if (result?.block && /no editor|editor disconnected|no answer/.test(result.reason ?? "")) break; // nobody is reviewing; stop asking
	}

	if (outcomes.every((o) => !o.result?.block)) {
		return { reviewed: outcomes.map((o) => ({ id: o.id, path: o.change.abs })), approved: new Map(outcomes.map((o) => [o.change.abs, o.change.final])) };
	}

	// Something was declined: the cell must not run. Files the user did accept in full are written
	// here (the core already wrote partially accepted ones), so their decision is not lost.
	const lines: string[] = [];
	for (const o of outcomes) {
		if (!o.result?.block) {
			const disk = readDisk(o.change.abs);
			fs.writeFileSync(o.change.abs, encode(o.change.final, disk ?? { bom: false, crlf: false }));
			await handlers.tool_result?.({ toolName: "write", toolCallId: o.id, input: { path: o.change.abs }, isError: false }, ctx());
			lines.push(`- ${o.rel}: accepted and written by the user's editor.`);
		} else {
			lines.push(`- ${o.rel}: ${String(o.result.reason).split("\n")[0]}`);
		}
	}
	return {
		block: true,
		reason:
			"The user reviewed the file edits in this ipython cell in their editor, and the cell was NOT executed " +
			"(nothing else in it ran). Outcome per file:\n" + lines.join("\n") +
			"\nDo not retry declined edits unless asked; re-read files before editing them again.",
	};
}

async function onMessage(msg: any) {
	const { id, method, params } = msg;
	if (method === undefined) return; // response to one of our requests

	try {
		switch (method) {
			case "initialize":
				cwd = params?.cwd ?? cwd;
				console.error(`ryno: initialize cwd=${cwd} pid=${process.pid}`);
				reply(id, { protocolVersion: 3 });
				await handlers.session_start?.({}, ctx());
				hostRequest("prompt/setSuffix", { text: mode() === "block" ? BLOCK_PROMPT.replace("the edit tool (or write for new files)", "the edit() function") : null });
				return;

			case "tool/beforeCall": {
				const toolId = randomUUID();
				const args = params?.args ?? {};
				// The user may still be reviewing what the previous command did: keep the agent waiting.
				if (postBusy) {
					const st = await Promise.race([postWork.then(() => "done"), new Promise((r) => setTimeout(() => r("busy"), GATE_BUDGET_MS))]);
					if (st === "busy") return reply(id, { block: true, reason: "[ryno] The user is still reviewing file changes made by your previous command in their editor. Wait a moment, then retry this call." });
				}
				if (undelivered) {
					const text = undelivered;
					undelivered = null;
					return reply(id, { block: true, reason: text + " This call was NOT run; re-issue it if it is still needed." });
				}
				if (process.env.RYNO_DEBUG) console.error(`ryno: gate ${params?.toolName}`);
				let result: any;
				try {
					result = await handlers.tool_call?.({ toolName: params?.toolName, toolCallId: toolId, input: args }, ctx());
				} catch (err) {
					console.error("ryno: gate failed, allowing:", err); // never wedge the agent on our own bug
				}
				if (result?.block) return reply(id, { block: true, reason: result.reason });
				if (params?.toolName === "edit" && typeof args.path === "string") remember("edit", args, { files: [{ id: toolId, path: args.path }] });
				const snapshotIf = () => (mode() === "block" || (mode() === "review" && api()?.hasEditors()) ? takeSnapshot(cwd) : null);
				if (params?.toolName === "bash") remember("bash", args, { files: [], snap: snapshotIf() });
				if (params?.toolName === "ipython" && typeof args.code === "string") {
					let g: Awaited<ReturnType<typeof gateIpython>>;
					try {
						g = await gateIpython(args.code);
					} catch (err) {
						console.error("ryno: ipython gate failed, allowing:", err);
					}
					if (g && "block" in g) return reply(id, { block: true, reason: g.reason });
					remember("ipython", args, { files: g && "reviewed" in g ? g.reviewed : [], approved: g && "reviewed" in g ? g.approved : undefined, snap: snapshotIf() });
				}
				return reply(id, { block: false });
			}

			case "event":
				if (params?.type === "agent_start") agentRunning = true;
				if (params?.type === "agent_end") {
					agentRunning = false;
					if (undelivered && !postBusy) {
						hostRequest("session/sendMessage", { text: undelivered, deliverAs: "followUp" });
						undelivered = null;
					}
				}
				if (params?.type === "tool_execution_end" && params.args !== undefined) {
					const k = callKey(params.toolName, params.args);
					const e = allowed.get(k)?.shift();
					if (allowed.get(k)?.length === 0) allowed.delete(k);
					if (e) {
						for (const f of e.files) {
							await handlers.tool_result?.({ toolName: "edit", toolCallId: f.id, input: { path: f.path }, isError: !!params.isError }, ctx());
						}
						if (e.snap) schedulePost(() => reviewAfter(params.toolName, e));
					}
				}
				return;

			default:
				if (id !== undefined) fail(id, -32601, `method not found: ${method}`);
		}
	} catch (err: any) {
		if (id !== undefined) fail(id, -32000, String(err?.message ?? err));
		else console.error("ryno:", err);
	}
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
	if (!line.trim()) return;
	try {
		void onMessage(JSON.parse(line));
	} catch {}
});
// Extensions must exit when stdin closes; also clean up (socket + descriptor) on signals.
let quitting = false;
const quit = async () => {
	if (quitting) return;
	quitting = true;
	try { await handlers.session_shutdown?.({ reason: "quit" }, ctx()); } catch {}
	process.exit(0);
};
rl.on("close", quit);
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(sig, quit);
