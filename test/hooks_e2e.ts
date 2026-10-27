// bun test/hooks_e2e.ts — Claude Code / Codex hooks: real hook processes + daemon + headless nvim.
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const hookJs = path.join(root, "extension/hooks/ryno-hook.ts");
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynoh-"));
const rt = path.join(tmp, "rt"), work = path.join(tmp, "proj"), planFile = path.join(tmp, "plan.json"), log = path.join(tmp, "nvim.log");
fs.mkdirSync(work);

const w = (f: string, t: string) => fs.writeFileSync(path.join(work, f), t);
const r = (f: string) => fs.readFileSync(path.join(work, f), "utf8");
const A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
for (const f of ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "p1.txt", "p2.txt"]) w(f, A);
spawnSync("sh", ["-c", "git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init"], { cwd: work });

const plan = (seq: string[]) => fs.writeFileSync(planFile, JSON.stringify({ seq }));
plan([]);
const env = { ...process.env, RYNO_DIR: rt, RYNO_BASH: "review", RYNO_ALLOW_ACCEPTED: "1", RYNO_SETTINGS: "/nonexistent" };
delete (env as any).RYNO_AGENT_PID;

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };
const logs = () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
const descriptors = () => (fs.existsSync(rt) ? fs.readdirSync(rt).filter((f) => /^\d+\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(rt, f), "utf8"))) : []);

/** Run the hook like the agent does (this process plays the agent). Resolves with its parsed stdout. */
function hook(agent: string, input: any, opts: { killAfter?: number } = {}) {
  return new Promise<any>((res) => {
    const p = spawn("node", [hookJs, agent], { env, stdio: ["pipe", "pipe", "inherit"] });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("exit", () => res(out.trim() ? JSON.parse(out) : null));
    p.stdin.end(JSON.stringify({ session_id: "s1", cwd: work, ...input }));
    if (opts.killAfter) setTimeout(() => p.kill("SIGTERM"), opts.killAfter);
    setTimeout(() => p.kill("SIGKILL"), 20000); // never hang the suite
  });
}
const pre = (tool_name: string, tool_input: any, id: string, o?: any) => hook("claude", { hook_event_name: "PreToolUse", tool_name, tool_input, tool_use_id: id }, o);
const post = (tool_name: string, tool_input: any, id: string, extra: any = {}) => hook("claude", { hook_event_name: "PostToolUse", tool_name, tool_input, tool_use_id: id, ...extra });
const decision = (o: any) => o?.hookSpecificOutput?.permissionDecision;
const reason = (o: any) => String(o?.hookSpecificOutput?.permissionDecisionReason ?? "");

console.log("SessionStart starts a daemon for this agent process");
const ss = await hook("claude", { hook_event_name: "SessionStart", source: "startup" });
ok(ss === null, "no output outside block mode");
const d0 = descriptors();
ok(d0.length === 1 && d0[0].agent === "claude-code" && d0[0].cwd === work && d0[0].sessionId === "s1", "descriptor: " + JSON.stringify(d0.map((d) => [d.agent, d.cwd, d.sessionId])));
ok(fs.existsSync(path.join(rt, `hook-${process.pid}.sock`)), "control socket keyed by the agent pid");

const nvim = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile " + root + "/test/nvim_driver.lua", path.join(work, "a.txt")], {
  cwd: work, env: { ...env, RYNO_ROOT: root, RYNO_PLAN_FILE: planFile, RYNO_LOG: log }, stdio: "ignore",
});
await Bun.sleep(1500);

console.log("Claude Write: partial accept -> denied, accepted hunk written");
plan(["partial"]);
let o = await pre("Write", { file_path: path.join(work, "a.txt"), content: A.replace("one", "ONE").replace("seven", "SEVEN") }, "t1");
ok(decision(o) === "deny" && /accepted only 1 of 2/.test(reason(o)), "deny: " + reason(o).slice(0, 80));
ok(r("a.txt") === A.replace("one", "ONE"), "first hunk on disk");

console.log("Claude Edit: accepted -> allowed (RYNO_ALLOW_ACCEPTED=1), editor told when applied");
plan(["accept_all"]);
o = await pre("Edit", { file_path: path.join(work, "a.txt"), old_string: "two", new_string: "TWO" }, "t2");
ok(decision(o) === "allow", "allow: " + JSON.stringify(o));
w("a.txt", r("a.txt").replace("two", "TWO")); // the tool runs
const applied0 = logs().filter((l) => l.ev === "applied").length;
o = await post("Edit", { file_path: path.join(work, "a.txt") }, "t2");
await Bun.sleep(300);
const ap = logs().filter((l) => l.ev === "applied");
ok(o === null && ap.length === applied0 + 1 && ap[ap.length - 1].text.startsWith("ONE|TWO"), "applied sent to the editor, buffer reloaded");

console.log("Claude MultiEdit: rejected -> denied, untouched");
plan(["reject_all"]);
o = await pre("MultiEdit", { file_path: path.join(work, "c.txt"), edits: [{ old_string: "one", new_string: "1" }, { old_string: "1\ntwo", new_string: "1\n2" }] }, "t3");
ok(decision(o) === "deny" && /rejected/.test(reason(o)), "deny: " + reason(o).slice(0, 60));
ok(r("c.txt") === A, "c.txt untouched");
const lastReview = logs().filter((l) => l.ev === "review").pop();
ok(lastReview?.buftext?.startsWith("1|2|three"), "reviewed the sequential result: " + lastReview?.buftext?.slice(0, 20));

console.log("Edit that the tool itself would reject passes through unreviewed");
const nrev = logs().filter((l) => l.ev === "review").length;
o = await pre("Edit", { file_path: path.join(work, "c.txt"), old_string: "not there", new_string: "x" }, "t4");
ok(o === null && logs().filter((l) => l.ev === "review").length === nrev, "no review, no decision");

console.log("hook killed mid-review (agent timeout / interrupt) -> review withdrawn, next one still works");
plan([]); // the 'user' does not answer
o = await pre("Edit", { file_path: path.join(work, "d.txt"), old_string: "two", new_string: "2" }, "t5", { killAfter: 1200 });
plan(["accept_all"]);
o = await pre("Edit", { file_path: path.join(work, "d.txt"), old_string: "three", new_string: "3" }, "t6");
ok(decision(o) === "allow", "later review answered: " + JSON.stringify(o));

console.log("Bash (review mode): change reviewed after the command, rejected -> rolled back");
plan(["reject_all"]);
o = await pre("Bash", { command: "sed -i '' s/four/4/ e.txt" }, "t7");
ok(o === null, "command allowed to run");
w("e.txt", A.replace("four", "4")); // the command runs
o = await post("Bash", { command: "…" }, "t7", { tool_response: { stdout: "", stderr: "" } });
const ctx = String(o?.hookSpecificOutput?.additionalContext ?? "");
ok(/ROLLED BACK[^]*e\.txt/.test(ctx) && o?.hookSpecificOutput?.hookEventName === "PostToolUse", "agent told: " + ctx.slice(0, 90));
ok(r("e.txt") === A, "e.txt restored");

console.log("non-file tools are ignored without contacting the daemon");
o = await pre("Read", { file_path: path.join(work, "a.txt") }, "t8");
ok(o === null, "no output");

// ───── Codex, started through bin/ryno-codex (the daemon must exist before the first message) ─────
console.log("bin/ryno-codex: daemon up before the session starts; apply_patch reviewed per file");
const fake = path.join(tmp, "fake-codex");
const patch = `*** Begin Patch\n*** Update File: p1.txt\n@@\n-one\n+ONE\n*** Update File: ${path.join(work, "p2.txt")}\n@@\n-two\n+TWO\n*** Add File: new.txt\n+hi\n*** End Patch`;
fs.writeFileSync(path.join(tmp, "patch.json"), JSON.stringify({ session_id: "cx1", cwd: work, hook_event_name: "PreToolUse", tool_name: "apply_patch", tool_input: { command: patch }, tool_use_id: "cx-1" }));
fs.writeFileSync(fake, `#!/bin/sh
ls "${rt}" > "${tmp}/at-start.txt"
sleep 1.5
node "${hookJs}" codex < "${tmp}/patch.json" > "${tmp}/codex-out.json"
exit 0 # (keeps sh from exec-ing node: hooks are children of the agent)
`, { mode: 0o755 });
plan(["accept_all", "reject_all", "accept_all"]);
const cx = spawnSync("sh", [path.join(root, "bin/ryno-codex"), "exec", "hi"], { cwd: work, env: { ...env, RYNO_CODEX: fake }, encoding: "utf8", timeout: 20000 });
ok(cx.status === 0, "wrapper ran the fake codex: " + cx.stderr);
const atStart = fs.readFileSync(path.join(tmp, "at-start.txt"), "utf8");
ok(/^hook-\d+\.sock$/m.test(atStart.replace(`hook-${process.pid}.sock`, "")), "codex control socket existed before codex did anything: " + atStart.replace(/\n/g, " "));
const cout = JSON.parse(fs.readFileSync(path.join(tmp, "codex-out.json"), "utf8") || "null");
ok(decision(cout) === "deny" && /p1\.txt: accepted and written/.test(reason(cout)) && /p2\.txt: The user rejected/.test(reason(cout)) && /new\.txt: accepted and written/.test(reason(cout)), "per-file outcome: " + reason(cout).replace(/\n/g, " | ").slice(0, 300));
ok(r("p1.txt") === A.replace("one", "ONE") && r("p2.txt") === A && r("new.txt") === "hi\n", "accepted files written, rejected one untouched");
ok(!JSON.stringify(cout).includes('"allow"'), "codex never gets an allow decision");
await Bun.sleep(2500);
ok(!descriptors().some((d) => d.agent === "codex") && !fs.readdirSync(rt).some((f) => f.startsWith("hook-") && f !== `hook-${process.pid}.sock` && f !== `hook-${process.pid}.lock`), "codex daemon gone after codex exited: " + fs.readdirSync(rt).join(" "));

console.log("--config prints installable hooks");
const cfg = JSON.parse(spawnSync("node", [hookJs, "--config", "codex"], { encoding: "utf8" }).stdout);
ok(cfg.hooks.PreToolUse[0].matcher === "apply_patch|Bash" && cfg.hooks.PreToolUse[0].hooks[0].command.endsWith("ryno-hook.ts codex"), "codex config");

nvim.kill();
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
