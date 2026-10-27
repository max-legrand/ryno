/**
 * ryno hook for Claude Code and Codex (node >= 23.6 or bun).
 *
 *   node ryno-hook.ts claude|codex            the hook command: reads the hook event JSON on stdin
 *   node ryno-hook.ts --start claude|codex    start the review socket now, for $RYNO_AGENT_PID (bin/ryno-codex)
 *   node ryno-hook.ts --config claude|codex   print the hooks configuration to add to the agent's settings
 *
 * Kept free of heavy imports: it runs on every tool call. The work happens in ryno-daemon.ts, one per
 * agent process, which this starts on demand and talks to over a unix socket.
 */
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = process.env.RYNO_DIR || path.join("/tmp", `ryno-${process.getuid?.() ?? "u"}`);
const ctlPath = (pid: number) => path.join(dir, `hook-${pid}.sock`);
const TOOLS = new Set(["Write", "Edit", "MultiEdit", "Bash", "apply_patch", "shell", "exec_command", "local_shell"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "fish", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh"]);

function connect(sock: string, payload: unknown, timeoutMs?: number): Promise<any> {
	return new Promise((resolve) => {
		const c = net.createConnection(sock);
		let buf = "";
		const t = timeoutMs ? setTimeout(() => { c.destroy(); resolve(null); }, timeoutMs) : undefined;
		c.setEncoding("utf8");
		c.on("connect", () => c.write(JSON.stringify(payload) + "\n"));
		c.on("data", (d: string) => {
			buf += d;
			const nl = buf.indexOf("\n");
			if (nl < 0) return;
			clearTimeout(t);
			c.end();
			try { resolve(JSON.parse(buf.slice(0, nl))); } catch { resolve(null); }
		});
		c.on("error", () => { clearTimeout(t); resolve(null); });
		c.on("close", () => { clearTimeout(t); resolve(null); });
	});
}
const ping = async (pid: number) => !!(await connect(ctlPath(pid), { ping: true }, 1000))?.pong;

/**
 * The agent process this hook belongs to: $RYNO_AGENT_PID (set by bin/ryno-codex) if it is our
 * ancestor, else the nearest ancestor that is not a shell. Walking stops at a shell found *above* the
 * agent, so an agent started from another agent's tool shell does not borrow the outer one's socket.
 */
function agentPid(): number {
	const ppid = process.ppid;
	if (fs.existsSync(ctlPath(ppid))) return ppid; // the common case, without spawning ps
	const tree = new Map<number, { ppid: number; comm: string }>();
	const ps = spawnSync("ps", ["-A", "-o", "pid=,ppid=,comm="], { encoding: "utf8", timeout: 3000 });
	for (const line of (ps.stdout ?? "").split("\n")) {
		const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
		if (m) tree.set(Number(m[1]), { ppid: Number(m[2]), comm: path.basename(m[3].trim()).replace(/^-/, "") });
	}
	const wanted = Number(process.env.RYNO_AGENT_PID) || 0;
	let first = 0;
	for (let pid = ppid, i = 0; pid > 1 && i < 5; i++) {
		if (pid === wanted) return wanted;
		const p = tree.get(pid);
		if (!p) break;
		const shell = SHELLS.has(p.comm);
		if (!shell && !first) first = pid;
		else if (shell && first) break;
		pid = p.ppid;
	}
	return first || ppid;
}

async function ensureDaemon(agent: string, pid: number, cwd: string, wait: boolean): Promise<boolean> {
	if (await ping(pid)) return true;
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	spawn(process.execPath, [path.join(here, "ryno-daemon.ts"), "--agent", agent, "--pid", String(pid), "--cwd", cwd], {
		detached: true,
		stdio: "ignore",
	}).unref();
	if (!wait) return true;
	for (let i = 0; i < 60; i++) {
		await new Promise((r) => setTimeout(r, 50));
		if (await ping(pid)) return true;
	}
	return false;
}

function config(agent: string) {
	const command = `node ${shq(path.join(here, "ryno-hook.ts"))} ${agent}`;
	const T = Number(process.env.RYNO_HOOK_TIMEOUT) || 600;
	const h = (timeout: number) => [{ type: "command", command, timeout }];
	const matcher = agent === "codex" ? "apply_patch|Bash" : "Edit|MultiEdit|Write|Bash";
	const hooks: Record<string, unknown> = {
		SessionStart: [{ hooks: h(15) }],
		PreToolUse: [{ matcher, hooks: h(T) }],
		PostToolUse: [{ matcher, hooks: h(T) }],
		...(agent === "claude" ? { PostToolUseFailure: [{ matcher, hooks: h(T) }] } : {}),
		Stop: [{ hooks: h(T) }],
	};
	return { hooks };
}
const shq = (s: string) => (/^[\w@%+=:,./-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'");

async function readStdin(): Promise<string> {
	let s = "";
	for await (const chunk of process.stdin) s += chunk;
	return s;
}

async function main() {
	const [mode, maybeAgent] = process.argv.slice(2);
	if (mode === "--config") {
		process.stdout.write(JSON.stringify(config(maybeAgent === "codex" ? "codex" : "claude"), null, 2) + "\n");
		return;
	}
	if (mode === "--start") {
		const pid = Number(process.env.RYNO_AGENT_PID) || process.ppid;
		await ensureDaemon(maybeAgent === "claude" ? "claude" : "codex", pid, process.cwd(), false);
		return;
	}
	const agent = mode === "codex" ? "codex" : "claude";
	if ((process.env.RYNO_DISABLE ?? "") !== "") return;

	let input: any;
	try { input = JSON.parse(await readStdin()); } catch { return; }
	const ev = input?.hook_event_name;
	if ((ev === "PreToolUse" || ev === "PostToolUse" || ev === "PostToolUseFailure") && !TOOLS.has(input.tool_name)) return;

	const pid = agentPid();
	const startsDaemon = ev === "SessionStart" || ev === "PreToolUse";
	if (startsDaemon) {
		const cwd = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
		if (!(await ensureDaemon(agent, pid, cwd, true))) return noDaemon(ev);
	}
	const res = await connect(ctlPath(pid), { input, projectDir: process.env.CLAUDE_PROJECT_DIR });
	if (!res) return startsDaemon ? noDaemon(ev) : undefined;
	if (res.error) process.stderr.write(`ryno: ${res.error}\n`);
	if (res.output) process.stdout.write(JSON.stringify(res.output) + "\n");
}

/** The daemon could not be reached: the call goes ahead unreviewed unless RYNO_NO_EDITOR=block. */
function noDaemon(ev: string) {
	if (ev !== "PreToolUse" || process.env.RYNO_NO_EDITOR !== "block") return;
	process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "ryno: the review daemon is not running (RYNO_NO_EDITOR=block)" } }) + "\n");
}

main().then(
	() => process.exit(0),
	(err) => { process.stderr.write(`ryno hook: ${err?.message ?? err}\n`); process.exit(0); }, // never wedge the agent on our own bug
);
