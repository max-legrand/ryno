/**
 * ryno host for hook-based agents (Claude Code, Codex).
 *
 * Their hooks are short-lived processes, but editors need a socket that lives as long as the agent.
 * This daemon is that process: one per agent process, started by the SessionStart hook (or by
 * bin/ryno-codex before codex even opens), running the same core as the pi extension (../ryno.ts).
 * The hooks (ryno-hook.ts) hand it each event over a control socket and print its answer.
 *
 *   node ryno-daemon.ts --agent claude|codex --pid <agent pid> --cwd <dir>
 *
 * Exits when the agent process does.
 */
import ryno, { BLOCK_PROMPT, encode, readDisk, runtimeDir, type BashMode } from "../ryno.ts";
import { applyClaudeEdit, applyClaudeEdits, patchChanges, shellPatch, type FileChange } from "./edits.ts";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";

const arg = (name: string) => {
	const i = process.argv.indexOf("--" + name);
	return i > 0 ? process.argv[i + 1] : undefined;
};
const agent = arg("agent") === "codex" ? "codex" : "claude";
const agentPid = Number(arg("pid"));
if (!(agentPid > 1)) {
	console.error("ryno-daemon: --pid <agent pid> is required");
	process.exit(2);
}

// The agents run shell commands in their own sandbox (or none) and hooks can't safely rewrite them,
// so `block` mode reverts changes after the command instead of wrapping it in sandbox-exec.
process.env.RYNO_SANDBOX = "off";
process.env.RYNO_AGENT ??= agent === "codex" ? "codex" : "claude-code";
// A hook that outlives its timeout is killed and the agent goes ahead without it: answer first.
const HOOK_TIMEOUT_S = Number(process.env.RYNO_HOOK_TIMEOUT) || 600;
process.env.RYNO_TIMEOUT_MS ??= String(Math.max(5, HOOK_TIMEOUT_S - 10) * 1000);
const BUDGET_MS = Number(process.env.RYNO_TIMEOUT_MS);

const dir = runtimeDir();
const ctlPath = path.join(dir, `hook-${agentPid}.sock`);
const lockPath = path.join(dir, `hook-${agentPid}.lock`);

const alive = (pid: number) => {
	try { process.kill(pid, 0); return true; } catch (e: any) { return e?.code === "EPERM"; }
};
const dbg = (...a: unknown[]) => {
	if (process.env.RYNO_DEBUG) fs.appendFileSync("/tmp/ryno-debug.log", `${new Date().toISOString()} [daemon ${process.pid}] ${a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")}\n`);
};

// ── one daemon per agent process ──

function takeLock(): boolean {
	for (let attempt = 0; attempt < 2; attempt++) {
		try {
			const fd = fs.openSync(lockPath, "wx", 0o600);
			fs.writeSync(fd, String(process.pid));
			fs.closeSync(fd);
			return true;
		} catch (e: any) {
			if (e?.code !== "EEXIST") throw e;
			let other = 0, age = Infinity;
			try { other = Number(fs.readFileSync(lockPath, "utf8")); age = Date.now() - fs.statSync(lockPath).mtimeMs; } catch {}
			if ((other && alive(other)) || (!other && age < 2000)) return false; // live owner, or one still writing its pid
			try { fs.unlinkSync(lockPath); } catch {}
		}
	}
	return false;
}

fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
for (const f of fs.readdirSync(dir)) {
	const m = /^hook-(\d+)\.(sock|lock)$/.exec(f);
	if (m && !alive(Number(m[1]))) try { fs.unlinkSync(path.join(dir, f)); } catch {}
}
if (!alive(agentPid) || !takeLock()) process.exit(0);

// ── the core, driven through a pi-shaped API ──

const handlers: Record<string, (e: any, c: any) => any> = {};
ryno({ on: (name: string, h: any) => void (handlers[name] = h) } as any);
const api = () => (globalThis as any).__rynoApi as { hasEditors(): boolean; bashMode(): BashMode };

let session = { cwd: arg("cwd") ?? process.cwd(), id: "" };
const ctx = (cwd: string, signal?: AbortSignal) => ({ cwd, signal, ui: {}, sessionManager: { getSessionId: () => session.id } });

const applied = new Map<string, Array<{ id: string; abs: string }>>(); // tool_use_id -> files an allowed call changes
const openBash = new Map<string, string>(); // tool_use_id -> cwd, for bash calls with a snapshot pending

type Out = Record<string, unknown> | undefined;
const deny = (reason: string): Out => ({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } });
const lf = (s: string) => s.replace(/\r\n/g, "\n");

/** Review each changed file; allow the call when all are accepted, else block it and say what happened per file. */
async function gate(changes: FileChange[], label: string, id: string, cwd: string, signal: AbortSignal): Promise<Out> {
	if (changes.length === 0) return;
	const hadEditors = api().hasEditors();
	const started = Date.now();
	const outcomes: Array<{ c: FileChange; id: string; result: any }> = [];
	for (const [k, c] of changes.entries()) {
		const subId = changes.length === 1 ? id : `${id}#${k}`;
		const rel = (p: string) => path.relative(cwd, p) || p;
		const result = await handlers.tool_call(
			{
				toolName: "write",
				toolLabel: c.from ? `${label} (moved from ${rel(c.from)})` : c.proposed === null ? `${label} (delete)` : label,
				toolCallId: subId,
				timeoutMs: Math.max(1000, BUDGET_MS - (Date.now() - started)),
				deleted: c.proposed === null,
				input: { path: c.abs, content: c.proposed ?? "" },
			},
			ctx(cwd, signal),
		);
		outcomes.push({ c, id: subId, result });
		if (result?.block && /no editor|editor disconnected|no answer|aborted/.test(result.reason ?? "")) break; // nobody is reviewing
	}

	if (outcomes.length === changes.length && outcomes.every((o) => !o.result?.block)) {
		applied.set(id, outcomes.map((o) => ({ id: o.id, abs: o.c.abs })));
		if (agent === "claude" && hadEditors && process.env.RYNO_ALLOW_ACCEPTED === "1") {
			return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "accepted in the editor (ryno)" } };
		}
		return;
	}
	if (changes.length === 1) return deny(outcomes[0].result.reason);

	// Something was declined, so the call must not run. Files the user accepted in full are written here
	// (the core already wrote partially accepted ones), so their decision is not lost.
	const lines: string[] = [];
	for (const [k, c] of changes.entries()) {
		const o = outcomes[k];
		const rel = path.relative(cwd, c.abs) || c.abs;
		if (!o) { lines.push(`- ${rel}: not reviewed, not written.`); continue; }
		if (o.result?.block) { lines.push(`- ${rel}: ${String(o.result.reason).split("\n")[0]}`); continue; }
		try {
			if (c.proposed === null) fs.rmSync(c.abs, { force: true });
			else {
				fs.mkdirSync(path.dirname(c.abs), { recursive: true });
				fs.writeFileSync(c.abs, encode(c.proposed, readDisk(c.from ?? c.abs) ?? { bom: false, crlf: false }));
				if (c.from) fs.rmSync(c.from, { force: true });
			}
			await handlers.tool_result({ toolName: "write", toolCallId: o.id, input: { path: c.abs }, isError: false }, ctx(cwd));
			lines.push(`- ${rel}: accepted and written by the user's editor${c.proposed === null ? " (deleted)" : c.from ? ` (moved from ${path.relative(cwd, c.from)})` : ""}.`);
		} catch (err: any) {
			lines.push(`- ${rel}: accepted, but writing it failed: ${err?.message ?? err}`);
		}
	}
	return deny(
		`The user reviewed the file changes in this ${label} call in their editor, and the call was NOT executed as a whole. Outcome per file:\n` +
			lines.join("\n") +
			"\nDo not retry declined changes unless asked; re-read files before editing them again.",
	);
}

async function gatePatch(patch: unknown, cwd: string, id: string, signal: AbortSignal): Promise<Out> {
	if (typeof patch !== "string") return;
	const changes = patchChanges(patch, cwd, (abs) => readDisk(abs)?.text ?? null);
	if (!changes) return void dbg("skip: patch does not apply", id); // apply_patch reports the error itself
	return gate(changes, "apply_patch", id, cwd, signal);
}

async function preToolUse(inp: any, cwd: string, signal: AbortSignal): Promise<Out> {
	const ti = inp.tool_input ?? {};
	const id = String(inp.tool_use_id ?? randomUUID());
	const tool = String(inp.tool_name ?? "");

	if (tool === "Bash" || tool === "shell" || tool === "exec_command" || tool === "local_shell") {
		const cmd = typeof ti.command === "string" ? ti.command : Array.isArray(ti.command) ? ti.command.join(" ") : typeof ti.cmd === "string" ? ti.cmd : null;
		if (cmd === null) return;
		const sp = shellPatch(cmd, cwd);
		if (sp) return gatePatch(sp.patch, sp.cwd, id, signal);
		await handlers.tool_call({ toolName: "bash", toolCallId: id, input: { command: cmd } }, ctx(cwd));
		if (api().bashMode() !== "off") openBash.set(id, cwd);
		return;
	}
	if (tool === "apply_patch") return gatePatch(ti.command ?? ti.input ?? ti.patch, cwd, id, signal);

	if (tool !== "Write" && tool !== "Edit" && tool !== "MultiEdit") return;
	if (typeof ti.file_path !== "string") return;
	const abs = path.resolve(cwd, ti.file_path);
	const before = readDisk(abs)?.text ?? null;
	let proposed: string | null;
	if (tool === "Write") proposed = typeof ti.content === "string" ? lf(ti.content) : null;
	else if (tool === "Edit") proposed = applyClaudeEdit(before, ti);
	else proposed = applyClaudeEdits(before, ti.edits);
	if (proposed === null) return void dbg("skip:", tool, "not reproducible against", abs); // the tool reports its own error
	return gate([{ abs, original: before, proposed }], tool, id, cwd, signal);
}

/** Review / revert what a shell command changed (bash mode review / block). Returns a note for the agent. */
async function finishBash(id: string, response: unknown): Promise<string | undefined> {
	const cwd = openBash.get(id);
	openBash.delete(id);
	if (cwd === undefined) return;
	const text = typeof response === "string" ? response : JSON.stringify(response ?? "");
	const r = await handlers.tool_result({ toolName: "bash", toolCallId: id, content: [{ type: "text", text }] }, ctx(cwd));
	const notes = (r?.content ?? []).slice(1).map((c: any) => c?.text).filter(Boolean);
	return notes.length ? notes.join("\n") : undefined;
}

async function postToolUse(inp: any, cwd: string): Promise<Out> {
	const id = String(inp.tool_use_id ?? "");
	const files = applied.get(id);
	if (files) {
		applied.delete(id);
		for (const f of files) await handlers.tool_result({ toolName: "write", toolCallId: f.id, input: { path: f.abs }, isError: inp.hook_event_name === "PostToolUseFailure" }, ctx(cwd));
		return;
	}
	const note = await finishBash(id, inp.tool_response ?? inp.error);
	return note ? { hookSpecificOutput: { hookEventName: inp.hook_event_name, additionalContext: note } } : undefined;
}

async function handle(req: any, signal: AbortSignal): Promise<Out> {
	const inp = req.input ?? {};
	const cwd = typeof inp.cwd === "string" && inp.cwd ? inp.cwd : session.cwd;
	// Editors match on the project dir; Claude's cwd follows `cd` in its shell, CLAUDE_PROJECT_DIR does not.
	const home = typeof req.projectDir === "string" && req.projectDir ? req.projectDir : cwd;
	const sid = typeof inp.session_id === "string" ? inp.session_id : session.id;
	if (home !== session.cwd || sid !== session.id) {
		session = { cwd: home, id: sid };
		await handlers.session_start({}, ctx(home));
	}
	dbg("hook", inp.hook_event_name, inp.tool_name ?? "");
	switch (inp.hook_event_name) {
		case "SessionStart":
			return api().bashMode() === "block" ? { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: BLOCK_PROMPT } } : undefined;
		case "PreToolUse":
			return preToolUse(inp, cwd, signal);
		case "PostToolUse":
		case "PostToolUseFailure":
			return postToolUse(inp, cwd);
		case "Stop": {
			// A command whose PostToolUse never came (failed, interrupted): settle its snapshot now.
			const notes: string[] = [];
			for (const id of [...openBash.keys()]) { const n = await finishBash(id, ""); if (n) notes.push(n); }
			applied.clear();
			return notes.length ? { systemMessage: notes.join("\n") } : undefined;
		}
	}
}

// ── control socket for the hooks: one JSON request line in, one JSON answer line out ──

const server = net.createServer((sock) => {
	const ac = new AbortController();
	let buf = "", started = false, done = false;
	sock.setEncoding("utf8");
	sock.on("data", (chunk: string) => {
		buf += chunk;
		const nl = buf.indexOf("\n");
		if (nl < 0 || started) return;
		started = true;
		let req: any;
		try { req = JSON.parse(buf.slice(0, nl)); } catch { return void sock.end(JSON.stringify({ error: "bad request" }) + "\n"); }
		if (req.ping) return void sock.end(JSON.stringify({ pong: process.pid }) + "\n");
		handle(req, ac.signal)
			.then((output) => ({ output: output ?? null }))
			.catch((err) => (dbg("handler failed", String(err?.stack ?? err)), { error: String(err?.message ?? err) }))
			.then((res) => { done = true; if (!sock.destroyed) sock.end(JSON.stringify(res) + "\n"); });
	});
	// The hook was killed (agent timeout / user interrupt): withdraw its review from the editors.
	sock.on("close", () => { if (!done) ac.abort(); });
	sock.on("error", () => {});
});

let quitting = false;
async function quit() {
	if (quitting) return;
	quitting = true;
	try { await handlers.session_shutdown?.({ reason: "quit" }, ctx(session.cwd)); } catch {}
	server.close();
	for (const f of [ctlPath, lockPath]) try { fs.unlinkSync(f); } catch {}
	process.exit(0);
}

try { fs.unlinkSync(ctlPath); } catch {}
server.on("error", (err) => { dbg("control socket failed", String(err)); void quit(); });
server.listen(ctlPath, async () => {
	try { fs.chmodSync(ctlPath, 0o600); } catch {}
	await handlers.session_start({}, ctx(session.cwd));
	dbg("up for", agent, agentPid, "in", session.cwd);
});
setInterval(() => { if (!alive(agentPid)) void quit(); }, 1000);
process.on("SIGTERM", quit);
process.on("uncaughtException", (err) => dbg("uncaught", String(err?.stack ?? err))); // keep serving the other reviews
process.on("SIGINT", () => {}); // detached, but don't die with a terminal's process group
process.on("SIGHUP", () => {});
