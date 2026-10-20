// bun test/prime_block.ts — prime-agent adapter with RYNO_BASH=block (no editor needed).
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynopb-"));
const work = path.join(tmp, "proj");
fs.mkdirSync(work);
fs.writeFileSync(path.join(work, "a.py"), "x = 1\n");
spawnSync("sh", ["-c", "git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm i"], { cwd: work });

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

const shim = spawn("node", [path.join(root, "extension/prime/ryno-prime.ts")], {
  cwd: path.join(root, "extension/prime"), env: { ...process.env, RYNO_DIR: path.join(tmp, "rt"), RYNO_BASH: "block" }, stdio: ["pipe", "pipe", "inherit"],
});
const waiters = new Map<number, (m: any) => void>();
const hostReqs: any[] = [];
let buf = "";
shim.stdout.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    if (m.method) hostReqs.push(m); else waiters.get(m.id)?.(m);
  }
});
let n = 0;
const rpc = (method: string, params: any) => new Promise<any>((res) => { const id = ++n; waiters.set(id, res); shim.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); });
const notify = (method: string, params: any) => shim.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
const read = (f: string) => fs.readFileSync(path.join(work, f), "utf8");

await rpc("initialize", { protocolVersion: 3, name: "ryno", cwd: work });
await Bun.sleep(300);
const suffix = hostReqs.find((m) => m.method === "prompt/setSuffix");
ok(suffix && /edit\(\) function/.test(suffix.params.text), "prompt suffix set for the agent");

console.log("cell writing a file directly -> runs, change reverted, agent told on its next call");
notify("event", { type: "agent_start" });
const code = "open('a.py','w').write('hacked\\n')";
ok((await rpc("tool/beforeCall", { toolName: "ipython", args: { code } })).result.block === false, "cell allowed to run");
fs.writeFileSync(path.join(work, "a.py"), "hacked\n");
notify("event", { type: "tool_execution_end", toolName: "ipython", args: { code }, isError: false });
const next = await rpc("tool/beforeCall", { toolName: "bash", args: { command: "ls" } });
ok(read("a.py") === "x = 1\n", "a.py reverted");
ok(next.result.block === true && /REVERTED: a\.py/.test(next.result.reason), "next call carries the note: " + next.result.reason.slice(0, 90));

console.log("edit() with runtime-computed arguments is refused before running");
const dyn = await rpc("tool/beforeCall", { toolName: "ipython", args: { code: 's = open("a.py").read()\nawait edit(path="a.py", old_str=s[:5], new_str="y")' } });
ok(dyn.result.block === true && /NOT run/.test(dyn.result.reason), "blocked up front");

console.log("statically known edit() is allowed (no editor -> passes like any edit), and is NOT reverted");
const codeE = 'await edit(path="a.py", old_str="x = 1", new_str="x = 2")';
ok((await rpc("tool/beforeCall", { toolName: "ipython", args: { code: codeE } })).result.block === false, "allowed");
fs.writeFileSync(path.join(work, "a.py"), "x = 2\n");
notify("event", { type: "tool_execution_end", toolName: "ipython", args: { code: codeE }, isError: false });
await Bun.sleep(500);
ok(read("a.py") === "x = 2\n", "kept");

shim.stdin.end();
await new Promise((r) => shim.on("exit", r));
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
