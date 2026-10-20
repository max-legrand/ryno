// bun test/prime_shim.ts — acts as the prime-agent host: spawns the v3 shim under node and gates tool calls.
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.mkdtempSync("/tmp/rynop-");
const rt = path.join(tmp, "rt"), work = path.join(tmp, "proj"), log = path.join(tmp, "nvim.log");
fs.mkdirSync(work);
fs.writeFileSync(path.join(work, "f.txt"), "one\ntwo\nthree\n");

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

const shim = spawn("node", [path.join(root, "extension/prime/ryno-prime.ts")], {
  cwd: path.join(root, "extension/prime"), env: { ...process.env, RYNO_DIR: rt, RYNO_BASH: "review" }, stdio: ["pipe", "pipe", "inherit"],
});
const waiters = new Map<number, (m: any) => void>();
const unsolicited: any[] = [];
let buf = "";
shim.stdout.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    if (m.method) unsolicited.push(m); else waiters.get(m.id)?.(m);
  }
});
let n = 0;
const rpc = (method: string, params: any) => new Promise<any>((res) => {
  const id = ++n; waiters.set(id, res);
  shim.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
});
const notify = (method: string, params: any) => shim.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");

const init = await rpc("initialize", { protocolVersion: 3, name: "ryno", cwd: work, host: { name: "prime-agent", version: "x" } });
ok(init.result?.protocolVersion === 3, "initialize -> protocol 3");

const planFile = path.join(tmp, "plan.json");
const plan: any = new Proxy({ "*": "partial" } as any, { set(t, k, v) { t[k] = v; fs.writeFileSync(planFile, JSON.stringify(t)); return true; } });
fs.writeFileSync(planFile, JSON.stringify({ "*": "partial" }));
const nvim = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set noswapfile", "-c", "luafile " + root + "/test/nvim_driver.lua", path.join(work, "f.txt")], {
  cwd: work, env: { ...process.env, RYNO_DIR: rt, RYNO_ROOT: root, RYNO_PLAN_FILE: planFile, RYNO_LOG: log }, stdio: "ignore",
});
await Bun.sleep(1500);

const bash = await rpc("tool/beforeCall", { toolName: "bash", args: { command: "ls" } });
ok(bash.result?.block === false, "non-edit tool passes");

const r = await rpc("tool/beforeCall", { toolName: "edit", args: { path: "f.txt", edits: [{ oldText: "one", newText: "ONE" }, { oldText: "three", newText: "THREE" }] } });
ok(r.result?.block === true && /accepted only 1 of 2/.test(r.result.reason), "partial accept -> blocked with explanation");
ok(fs.readFileSync(path.join(work, "f.txt"), "utf8") === "ONE\ntwo\nthree\n", "accepted hunk written");

// legacy top-level oldText/newText
plan["*"] = "partial";
const r2 = await rpc("tool/beforeCall", { toolName: "edit", args: { path: "f.txt", oldText: "two", newText: "TWO" } });
ok(r2.result && "block" in r2.result, "legacy args handled: " + JSON.stringify(r2.result).slice(0, 80));

// ───── ipython cells (how prime-agent's model really edits) ─────
const readf = (f: string) => fs.readFileSync(path.join(work, f), "utf8");
const ip = (code: string) => rpc("tool/beforeCall", { toolName: "ipython", args: { code } });
const readLog = () => fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
fs.writeFileSync(path.join(work, "a.py"), "x = 1\ny = 2\nz = 3\n");
fs.writeFileSync(path.join(work, "b.py"), "def f():\n    return 1\n");

console.log("ipython: two edits to one file via variables + triple quotes -> ONE review of the net change");
const before = readLog().filter((o) => o.ev === "review").length;
plan.seq = ["accept_all"];
const code1 = "old = \'\'\'x = 1\'\'\'\nnew = \'\'\'x = 10\'\'\'\nprint(await edit(path=\"a.py\", old_str=old, new_str=new))\nprint(await edit('a.py', 'z = 3', 'z = 30'))\n";
const c1 = await ip(code1);
ok(c1.result?.block === false, "accepted -> cell allowed");
ok(readLog().filter((o) => o.ev === "review").length === before + 1, "one review for two edits to the same file");
notify("event", { type: "tool_execution_end", toolName: "ipython", isError: false, args: { code: code1 } });
await Bun.sleep(400);
ok(readLog().some((o) => o.ev === "applied"), "editor told the file changed after the cell ran");

console.log("ipython: two files, first accepted, second rejected -> cell blocked, first still applied");
fs.writeFileSync(path.join(work, "a.py"), "x = 1\ny = 2\nz = 3\n");
plan.seq = ["accept_all", "reject_all"];
const c2 = await ip('await edit(path="a.py", old_str="y = 2", new_str="y = 20")\nawait edit(path="b.py", old_str="return 1", new_str="return 100")\n');
ok(c2.result?.block === true && /NOT executed/.test(c2.result.reason), "cell blocked: " + c2.result?.reason?.split("\n")[0]);
ok(/a\.py: accepted and written/.test(c2.result?.reason ?? "") && /b\.py: The user rejected/.test(c2.result?.reason ?? ""), "per-file outcome reported");
ok(readf("a.py") === "x = 1\ny = 20\nz = 3\n", "accepted file written by extension");
ok(readf("b.py") === "def f():\n    return 1\n", "rejected file untouched");

console.log("ipython: dynamic / looped edits and non-edit cells pass through unreviewed");
plan.seq = [];
const nrev = readLog().filter((o) => o.ev === "review").length;
const c3 = await ip('s = open("a.py").read()\nawait edit(path="a.py", old_str=s[0:5], new_str="q")');
const c4 = await ip('for f in ["a.py"]:\n    await edit(path=f, old_str="x", new_str="y")');
const c5 = await ip('print(1+1)');
const c6 = await ip('!ls');
ok([c3, c4, c5, c6].every((c) => c.result?.block === false), "all allowed");
ok(readLog().filter((o) => o.ev === "review").length === nrev, "no review requested");

// ───── commands that write files directly (python open().write, sed -i, heredocs): applied, then reviewed ─────
console.log("ipython/bash writing files directly: reviewed after the fact, rolled back on reject");
import { spawnSync } from "node:child_process";
const sh = (c: string) => spawnSync("sh", ["-c", c], { cwd: work, encoding: "utf8" });
fs.writeFileSync(path.join(work, "a.py"), "x = 1\ny = 2\n"); fs.writeFileSync(path.join(work, "b.py"), "p = 1\nq = 2\n");
sh("git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init");

plan.seq = ["reject_all"];
notify("event", { type: "agent_start" });
const code7 = 'open("a.py","w").write("hacked = True\\n")';
const g7 = await ip(code7);
ok(g7.result?.block === false, "cell allowed to run (nothing to review up front)");
fs.writeFileSync(path.join(work, "a.py"), "hacked = True\n"); // what the cell did
notify("event", { type: "tool_execution_end", toolName: "ipython", args: { code: code7 }, isError: false });
const next = await rpc("tool/beforeCall", { toolName: "bash", args: { command: "ls" } }); // agent's next call: held until the user decided
ok(next.result?.block === true && /ROLLED BACK[^]*a\.py/.test(next.result.reason), "next call is held, then carries the outcome: " + next.result?.reason?.slice(60, 150));
ok(readf("a.py") === "x = 1\ny = 2\n", "a.py rolled back");
const again = await rpc("tool/beforeCall", { toolName: "bash", args: { command: "ls" } });
ok(again.result?.block === false, "outcome is delivered once, then the agent proceeds");

console.log("turn already over -> outcome sent as a follow-up message");
plan.seq = ["reject_all"];
const code8 = "sed -i s/p/z/ b.py";
await rpc("tool/beforeCall", { toolName: "bash", args: { command: code8 } });
fs.writeFileSync(path.join(work, "b.py"), "z = 1\nq = 2\n");
notify("event", { type: "tool_execution_end", toolName: "bash", args: { command: code8 }, isError: false });
notify("event", { type: "agent_end" }); // no further call is coming
await Bun.sleep(3000);
const fu = unsolicited.find((m) => m.method === "session/sendMessage");
ok(fu && /ROLLED BACK/.test(fu.params.text) && fu.params.deliverAs === "followUp", "follow-up queued for the agent");
ok(readf("b.py") === "p = 1\nq = 2\n", "b.py rolled back");

console.log("edits already reviewed up front are not reviewed a second time");
plan.seq = ["accept_all"]; // answers the pre-review only; a second review would hang/need another answer
const codeE = 'await edit(path="a.py", old_str="y = 2", new_str="y = 20")';
const revBefore = readLog().filter((o) => o.ev === "review").length;
notify("event", { type: "agent_start" });
const gE = await ip(codeE);
ok(gE.result?.block === false, "reviewed + allowed");
fs.writeFileSync(path.join(work, "a.py"), "x = 1\ny = 20\n"); // the edit() the cell then performs
notify("event", { type: "tool_execution_end", toolName: "ipython", args: { code: codeE }, isError: false });
await Bun.sleep(1500);
ok(readLog().filter((o) => o.ev === "review").length === revBefore + 1, "exactly one review for that cell");

// applied notification for an allowed edit (single hunk accepted outright via nvim: use a fresh edit w/ accept plan)
notify("event", { type: "tool_execution_end", toolName: "edit", isError: false });
await Bun.sleep(200);

shim.stdin.end();
const code = await new Promise((res) => shim.on("exit", res));
ok(code === 0, "exits cleanly when stdin closes");
ok(!fs.readdirSync(rt).some((f) => f.endsWith(".sock")), "socket removed on exit");
nvim.kill();
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
