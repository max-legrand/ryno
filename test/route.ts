// bun test/route.ts — several nvims, one agent: reviews go to ONE nvim (file open > cwd > recency),
// and :RynoLink pins a session to an nvim (even one whose cwd doesn't match).
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/ryner-"));
const rt = path.join(tmp, "rt"), proj = path.join(tmp, "proj"), sub = path.join(proj, "sub"), other = path.join(tmp, "elsewhere");
for (const d of [proj, sub, other]) fs.mkdirSync(d, { recursive: true });
for (const [d, f] of [[proj, "a.txt"], [proj, "b.txt"], [proj, "c.txt"], [sub, "s.txt"], [other, "o.txt"]]) fs.writeFileSync(path.join(d, f), "alpha\nbeta\n");
const planFile = path.join(tmp, "plan.json");
fs.writeFileSync(planFile, JSON.stringify({ "*": "accept_all" }));

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

const nvims: Record<string, { log: string; sock: string; proc: ReturnType<typeof spawn> }> = {};
const startNvim = (name: string, cwd: string, file: string) => {
  const log = path.join(tmp, name + ".log"), sock = path.join(tmp, name + ".sock");
  const proc = spawn("nvim", ["--headless", "--listen", sock, "-u", "NONE", "-i", "NONE", "-c", "luafile " + root + "/test/nvim_driver.lua", file], {
    cwd, env: { ...process.env, RYNO_DIR: rt, RYNO_ROOT: root, RYNO_PLAN_FILE: planFile, RYNO_LOG: log }, stdio: "ignore",
  });
  fs.writeFileSync(log, "");
  nvims[name] = { log, sock, proc };
};
const reviewed = (name: string) => fs.readFileSync(nvims[name].log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((o) => o.ev === "review").length;
const expr = (name: string, e: string) => spawnSync("nvim", ["--headless", "--server", nvims[name].sock, "--remote-expr", e], { encoding: "utf8" }).stdout;

const agent = (cwd: string, file: string) => new Promise<any>((res) => {
  const p = spawn("bun", [path.join(root, "test/agent_child.ts")], { env: { ...process.env, RYNO_DIR: rt, CHILD_CWD: cwd, CHILD_FILE: file, CHILD_DELAY: "2500" }, stdio: ["ignore", "pipe", "inherit"] });
  let out = ""; p.stdout.on("data", (d) => (out += d)); p.on("exit", () => res(out.trim() ? JSON.parse(out) : null));
});
const agentPid = () => Number(fs.readdirSync(rt).map((f) => /^(\d+)\.json$/.exec(f)?.[1]).filter(Boolean).pop());

startNvim("n1", proj, path.join(proj, "a.txt")); // same cwd, other file
startNvim("n2", proj, path.join(proj, "b.txt")); // same cwd, has b.txt
startNvim("n3", sub, path.join(sub, "s.txt")); // deeper cwd, doesn't have it
startNvim("n4", other, path.join(other, "o.txt")); // unrelated cwd
fs.writeFileSync(path.join(proj, "d.jjdescription"), "alpha\nbeta\n");
startNvim("n5", proj, path.join(proj, "d.jjdescription")); // throwaway $EDITOR (jj desc): must be ignored
await Bun.sleep(800);

console.log("1. file open in exactly one nvim");
let r = await agent(proj, "b.txt");
ok(r && !r.blocked, "edit accepted");
ok(reviewed("n2") === 1 && reviewed("n1") === 0 && reviewed("n3") === 0 && reviewed("n4") === 0, "only n2 (has b.txt) reviewed");

console.log("2. nobody has the file: deepest cwd containing it wins");
// c.txt is in proj: n1/n2 have cwd proj, n3's cwd (proj/sub) does not contain it
r = await agent(proj, "c.txt");
ok(r && !r.blocked, "edit accepted");
const before = { n1: reviewed("n1"), n2: reviewed("n2") };
ok(reviewed("n3") === 0 && reviewed("n4") === 0, "not n3 (cwd doesn't contain it) or n4 (unrelated)");
ok(before.n1 + before.n2 === 2, "exactly one of n1/n2 got it (n2 had one already): n1=" + before.n1 + " n2=" + before.n2);

console.log("3. :RynoLink pins the session to an unrelated nvim");
const p3 = agent(proj, "a.txt");
await Bun.sleep(1200);
expr("n4", `luaeval("require('ryno').link(${agentPid()})")`);
r = await p3;
ok(r && !r.blocked, "edit accepted");
ok(reviewed("n4") === 1, "linked n4 (cwd unrelated, file not open) reviewed it");
ok(reviewed("n1") === before.n1 && reviewed("n2") === before.n2 && reviewed("n3") === 0, "n1/n2/n3 did not (even though n1 has a.txt open)");

console.log("4. a `jj desc`-style nvim is never connected, even though it has the file open");
r = await agent(proj, "d.jjdescription");
ok(r && !r.blocked, "edit accepted");
ok(reviewed("n5") === 0, "excluded n5 did not review");
ok(reviewed("n1") + reviewed("n2") === before.n1 + before.n2 + 1, "a regular nvim reviewed it instead");

for (const n of Object.values(nvims)) n.proc.kill();
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
