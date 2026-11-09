// bun test/review_mode.ts - review-only policy, human-save workflow, and adapter gates.
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import ryno, { loadRynoMode, saveRynoMode, REVIEW_PROMPT, REVIEW_REQUEST, reviewShellCommand } from "../extension/ryno.ts";

const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/ryno-review-"));
process.env.RYNO_DIR = path.join(tmp, "rt");
process.env.RYNO_SETTINGS = path.join(tmp, "settings.json");
process.env.RYNO_SOUND = "off";
delete process.env.RYNO_MODE;
let failed = 0;
const ok = (c: any, m: string) => { if (!c) failed++; console.log(c ? "  ok  " : "  FAIL", m); };
ok(loadRynoMode() === "edit", "editing remains the default");
const settingsFile = process.env.RYNO_SETTINGS;
process.env.RYNO_SETTINGS = path.join(tmp, "nested", "config", "settings.json");
saveRynoMode("review");
ok(loadRynoMode() === "review", "saving creates a missing settings file and its parent directories");
process.env.RYNO_SETTINGS = settingsFile;
fs.writeFileSync(settingsFile, JSON.stringify({ bash: "block", other: { keep: true }, mode: "edit" }));
saveRynoMode("review");
const saved = JSON.parse(fs.readFileSync(settingsFile, "utf8"));
ok(saved.mode === "review" && saved.bash === "block" && saved.other.keep === true, "saving preserves unrelated settings");
for (const bad of ["{broken", "[]", "null", "true", '"text"']) {
  fs.writeFileSync(settingsFile, bad);
  let threw = false;
  try { saveRynoMode("edit"); } catch { threw = true; }
  ok(threw && fs.readFileSync(settingsFile, "utf8") === bad, "invalid settings are not overwritten: " + bad);
}
ok(!fs.readdirSync(tmp).some((f) => f.endsWith(".tmp")), "no temporary settings files left behind");
fs.writeFileSync(settingsFile, JSON.stringify({ mode: "review" }));
ok(loadRynoMode() === "review", "settings enable review mode");
process.env.RYNO_MODE = "edit";
ok(loadRynoMode() === "edit", "environment overrides settings");
process.env.RYNO_MODE = "invalid";
ok(loadRynoMode() === "review", "invalid environment falls back to settings");
process.env.RYNO_MODE = "review";
process.env.RYNO_BASH = "off";
process.env.RYNO_NO_EDITOR = "allow";

const handlers: Record<string, Function> = {}, commands: Record<string, any> = {}, tools: Record<string, any> = {};
const messages: string[] = [], notices: string[] = [];
let idle = true, status = "", failSave = false;
let entries: any[] = [];
let piDefaults = { mode: "edit", bash: "block" };
const ctx = {
  cwd: tmp, isIdle: () => idle,
  ui: { setStatus: (_: string, s: string) => status = s, notify: (m: string) => notices.push(m) },
  sessionManager: { getSessionId: () => "review-test", getBranch: () => entries },
};
ryno({
  on: (n: string, h: Function) => handlers[n] = h,
  registerCommand: (n: string, c: any) => commands[n] = c,
  registerTool: (t: any) => tools[t.name] = t,
  sendUserMessage: (m: string) => messages.push(m),
  getSettings: () => ({ ryno: piDefaults }),
  appendEntry: (customType: string, data: any) => {
    if (failSave) throw new Error("session write failed");
    entries.push({ type: "custom", customType, data });
  },
} as any);
await handlers.session_start({}, ctx);
await Bun.sleep(50);
const call = (toolName: string, input: any = {}, extra = {}) => handlers.tool_call({ toolName, toolCallId: "t", input, ...extra }, ctx);
ok(status.includes("REVIEW ONLY"), "footer identifies review-only mode without an editor");
ok((await handlers.before_agent_start({ systemPrompt: "BASE" })).systemPrompt === "BASE\n\n" + REVIEW_PROMPT, "review prompt replaces conflicting bash editing guidance");
ok(REVIEW_PROMPT.includes("MUST call it before") && REVIEW_PROMPT.includes("how do I deep-copy this map?"), "annotation policy explicitly covers ordinary implementation questions before final answers");
ok(tools.ryno_findings.promptGuidelines.some((g: string) => g.includes("Do not wait for the user")), "tool prompt reinforces automatic annotation delivery");
for (const tool of ["edit", "write", "apply_patch", "ipython", "subagent", "codemode", "NotebookEdit", "unknown", "ffgrep_write", "fffind_exec"]) {
  ok((await call(tool, { path: "missing", content: "new" }))?.block, `${tool} blocked before validation/no-editor fallback`);
}
for (const tool of ["read", "grep", "find", "ls", "fffind", "ffgrep"]) ok(await call(tool) === undefined, `${tool} allowed`);
process.env.RYNO_SANDBOX = "off";
ok((await call("bash", { command: "echo x > file" }))?.block, "shell fails closed without sandbox even with bash off");
ok((await call("bash", { command: "ls" }, { readOnlyShell: false }))?.block, "hosts that cannot rewrite commands refuse shell calls");
delete process.env.RYNO_SANDBOX;

// An editor that auto-accepts everything must never receive a diff in this mode.
const editor = net.createConnection(path.join(process.env.RYNO_DIR!, `${process.pid}.sock`));
let wire = "";
editor.on("data", (d) => { wire += d; });
await new Promise<void>((resolve) => editor.once("connect", resolve));
await Bun.sleep(30);
const file = path.join(tmp, "code.txt");
fs.writeFileSync(file, "before\n");
ok((await call("write", { path: file, content: "agent proposal\n" }))?.block, "write also blocked with an editor connected");
await Bun.sleep(30);
ok(!wire.includes('"type":"review"') && fs.readFileSync(file, "utf8") === "before\n", "no approval diff and no agent write");
ok(await call("ryno_findings") === undefined, "read-only findings tool is allowed in review mode");
const findings = [{ path: "code.txt", line: 1, title: "Combine identical arrivals", body: "Count arrivals per node and energy level. Verify with a diamond graph." }];
const published = await tools.ryno_findings.execute("f", { findings }, undefined, undefined, ctx);
await Bun.sleep(30);
ok(!published.isError && wire.includes('"type":"findings"') && wire.includes("Combine identical arrivals"), "review comments delivered to editor, not approval diffs");
ok(fs.readFileSync(file, "utf8") === "before\n", "publishing findings never edits files");
let badLine = false;
try { await tools.ryno_findings.execute("f", { findings: [{ ...findings[0], line: 100 }] }, undefined, undefined, ctx); } catch { badLine = true; }
ok(badLine, "invalid source lines rejected before publishing");
await tools.ryno_findings.execute("f", { findings: [] }, undefined, undefined, ctx);
await Bun.sleep(30);
ok(wire.includes('"findings":[]'), "empty batch clears previous review comments");

fs.writeFileSync(file, "user implementation\n");
await handlers.tool_result({ toolName: "bash", toolCallId: "t", content: [] }, ctx);
ok(fs.readFileSync(file, "utf8") === "user implementation\n", "no shell snapshot can roll back a human save in review mode");
await commands["ryno-review"].handler("code.txt; check error paths", ctx);
ok(messages[0] === REVIEW_REQUEST + "\n\nReview scope / user note: code.txt; check error paths", "saved-change command requests fresh reads and scoped feedback");
ok(fs.readFileSync(file, "utf8") === "user implementation\n", "requesting review leaves user's saved changes untouched");
await commands["ryno-bash"].handler("off", ctx);
ok(notices.at(-1)?.includes("overrides bash"), "bash policy cannot disable review enforcement");
const beforeRejectedCommands = fs.readFileSync(settingsFile, "utf8");
idle = false;
await commands["ryno-mode"].handler("edit", ctx);
ok((await call("edit"))?.block, "cannot switch to editing during a run");
const count = messages.length;
await commands["ryno-review"].handler("", ctx);
ok(messages.length === count, "cannot race a review request with a running agent");
idle = true;
await commands["ryno-mode"].handler("typo", ctx);
ok((await call("write"))?.block, "invalid mode does not disable review enforcement");
await commands["ryno-mode"].handler("", ctx);
ok(fs.readFileSync(settingsFile, "utf8") === beforeRejectedCommands, "busy/invalid commands and status queries do not change saved settings");
failSave = true;
await commands["ryno-mode"].handler("edit", ctx);
ok((await call("edit"))?.block && notices.at(-1)?.includes("Mode unchanged"), "failed session save reports the error and leaves current mode unchanged");
failSave = false;
editor.destroy();
await Bun.sleep(30);
await commands["ryno-mode"].handler("edit", ctx);
ok(entries.at(-1).data.mode === "edit", "mode command persists selection in session history");
ok(fs.readFileSync(settingsFile, "utf8") === beforeRejectedCommands, "mode command never changes global defaults");
await handlers.session_start({}, ctx);
ok(entries.at(-1).data.mode === "edit", "saved session mode takes precedence over environment on reload");
ok(await call("edit", { path: file, edits: [{ oldText: "user", newText: "agent" }] }) === undefined, "normal no-editor behavior restored explicitly");
ok(await handlers.before_agent_start({ systemPrompt: "BASE" }) === undefined, "normal prompt restored");
await commands["ryno-review"].handler("", ctx);
ok(messages.length === count, "review command requires review mode");
delete process.env.RYNO_MODE;
await commands["ryno-mode"].handler("review", ctx);
await handlers.session_start({}, ctx);
ok((await call("write"))?.block, "saved review mode survives session startup without an environment override");
await commands["ryno-mode"].handler("edit", ctx);
await handlers.session_start({}, ctx);
ok(await call("write", { path: file, content: "proposal" }) === undefined, "saved edit mode also survives session startup");
await commands["ryno-bash"].handler("block", ctx);
await handlers.session_start({}, ctx);
ok(status.includes("bash read-only"), "bash policy survives reload");
const sessionA = entries;
entries = [];
delete process.env.RYNO_BASH;
piDefaults = { mode: "review", bash: "off" };
await handlers.session_start({}, ctx);
ok((await call("write"))?.block && entries[0].data.bash === "off", "new session uses Pi settings defaults");
piDefaults = { mode: "edit", bash: "block" };
await handlers.session_start({}, ctx);
ok((await call("write"))?.block, "changing defaults does not change an existing session");
entries = sessionA;
await handlers.session_start({}, ctx);
ok(status.includes("bash read-only") && !status.includes("REVIEW ONLY"), "resuming another session restores its own settings");
entries = [...sessionA, { type: "custom", customType: "ryno-settings", data: { mode: "review", bash: "off" } }];
await handlers.session_tree({}, ctx);
ok((await call("write"))?.block, "tree navigation restores active-branch settings");
entries = sessionA;
await handlers.session_tree({}, ctx);
ok(!status.includes("REVIEW ONLY"), "leaving a branch restores its original mode");
idle = false;
await commands["ryno-bash"].handler("off", ctx);
ok(status.includes("bash read-only"), "cannot change bash policy during a run");
idle = true;
await handlers.session_shutdown({});

// Real shell execution if the host supports it. No git repo, no snapshot, no rollback.
const wrapped = reviewShellCommand("printf inspected; printf changed > code.txt");
if (wrapped) {
  const r = spawnSync("bash", ["-c", wrapped], { cwd: tmp, encoding: "utf8" });
  ok(r.stdout.includes("inspected"), "sandbox permits shell research");
  ok(r.status !== 0 && fs.readFileSync(file, "utf8") === "user implementation\n", "sandbox denies writes in a non-git directory");
  const newFile = path.join(tmp, "new.txt");
  const ignored = path.join(tmp, "node_modules");
  fs.mkdirSync(ignored);
  for (const cmd of ["rm code.txt", "mv code.txt moved.txt", "echo new > new.txt", "echo cache > node_modules/cache", `echo x > '${tmp}/outside.txt'`]) {
    const result = spawnSync("bash", ["-c", reviewShellCommand(cmd)!], { cwd: tmp, encoding: "utf8" });
    ok(result.status !== 0, "sandbox refuses " + cmd);
  }
  ok(!fs.existsSync(newFile) && !fs.existsSync(path.join(ignored, "cache")), "no new files or ignored output left behind");
} else console.log("  SKIP real macOS sandbox unavailable (fail-closed path tested)");

const root = path.resolve(import.meta.dir, "..");
const env = { ...process.env, RYNO_MODE: "review", RYNO_SANDBOX: "off", RYNO_DIR: path.join(tmp, "prime-rt") };
const prime = spawn(process.execPath, [path.join(root, "extension/prime/ryno-prime.ts")], { cwd: tmp, env, stdio: ["pipe", "pipe", "ignore"] });
let output: any[] = [], buf = "";
prime.stdout.on("data", (d) => {
  buf += d;
  let n: number;
  while ((n = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, n); buf = buf.slice(n + 1); try { output.push(JSON.parse(line)); } catch {} }
});
async function waitFor(check: () => any) {
  for (let n = 0; n < 200; n++) { const r = check(); if (r) return r; await Bun.sleep(20); }
  throw new Error("timed out waiting for adapter");
}
let id = 0;
async function rpc(method: string, params: any) {
  const key = ++id;
  prime.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: key, method, params }) + "\n");
  return (await waitFor(() => output.find((r) => r.id === key && r.result))).result;
}
try {
  await rpc("initialize", { cwd: tmp });
  await waitFor(() => output.find((r) => r.method === "prompt/setSuffix"));
  ok(output.find((r) => r.method === "prompt/setSuffix").params.text === REVIEW_PROMPT, "prime-agent gets research/review prompt");
  for (const toolName of ["ipython", "bash", "write", "subagent"]) {
    ok((await rpc("tool/beforeCall", { toolName, args: { code: "open('code.txt','w').write('bad')", command: "ls" } })).block, `prime-agent blocks ${toolName}`);
  }
  ok(!(await rpc("tool/beforeCall", { toolName: "read", args: { path: file } })).block, "prime-agent allows reading");
} finally { prime.kill("SIGTERM"); await new Promise((r) => prime.once("exit", r)); }

// Actual hook CLI + daemon, including tools older configurations never sent to the gate.
const hookEnv = { ...env, RYNO_DIR: path.join(tmp, "hook-rt"), RYNO_AGENT_PID: String(process.pid) };
async function hook(input: any) {
  const p = spawn("node", [path.join(root, "extension/hooks/ryno-hook.ts"), "claude"], { cwd: tmp, env: hookEnv, stdio: ["pipe", "pipe", "inherit"] });
  let out = "";
  p.stdout.on("data", (d) => out += d);
  p.stdin.end(JSON.stringify({ cwd: tmp, session_id: "review", ...input }));
  await new Promise((r) => p.once("exit", r));
  return out.trim() ? JSON.parse(out) : null;
}
let daemonPid: number | undefined;
try {
  const start = await hook({ hook_event_name: "SessionStart" });
  ok(start?.hookSpecificOutput?.additionalContext === REVIEW_PROMPT, "hooks inject review-only guidance");
  const desc = fs.readdirSync(hookEnv.RYNO_DIR).find((f) => /^\d+\.json$/.test(f));
  if (desc) daemonPid = JSON.parse(fs.readFileSync(path.join(hookEnv.RYNO_DIR, desc), "utf8")).pid;
  for (const tool_name of ["Write", "Edit", "MultiEdit", "apply_patch", "Bash", "exec_command", "NotebookEdit", "Task", "mcp__files__write", "unknown"]) {
    const r = await hook({ hook_event_name: "PreToolUse", tool_name, tool_input: {}, tool_use_id: tool_name });
    ok(r?.hookSpecificOutput?.permissionDecision === "deny", `hook blocks ${tool_name} without editor`);
  }
  for (const tool_name of ["Read", "Grep", "Glob"]) {
    ok(await hook({ hook_event_name: "PreToolUse", tool_name, tool_input: {} }) === null, `hook allows ${tool_name}`);
  }
  const config = spawnSync("node", [path.join(root, "extension/hooks/ryno-hook.ts"), "--config", "claude"], { env: hookEnv, encoding: "utf8" });
  ok(JSON.parse(config.stdout).hooks.PreToolUse[0].matcher === "*", "new hook configuration gates all tools");
  ok(fs.readFileSync(file, "utf8") === "user implementation\n", "all adapters leave the user's implementation untouched");
} finally { if (daemonPid) process.kill(daemonPid, "SIGTERM"); }

// A reachable but broken daemon must not silently allow calls in review-only mode.
const ctl = path.join(hookEnv.RYNO_DIR, `hook-${process.pid}.sock`);
await waitFor(() => !fs.existsSync(ctl));
const broken = net.createServer((sock) => {
  let data = "";
  sock.on("data", (d) => {
    data += d;
    if (!data.includes("\n")) return;
    const req = JSON.parse(data.slice(0, data.indexOf("\n")));
    sock.end(JSON.stringify(req.ping ? { pong: process.pid } : { error: "simulated gate failure" }) + "\n");
  });
});
await new Promise<void>((resolve) => broken.listen(ctl, resolve));
try {
  const denied = await hook({ hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {} });
  ok(denied?.hookSpecificOutput?.permissionDecision === "deny", "hook fails closed on daemon errors even with RYNO_NO_EDITOR=allow");
} finally { await new Promise<void>((resolve) => broken.close(() => resolve())); }

console.log(failed ? `${failed} FAILED` : "ALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
