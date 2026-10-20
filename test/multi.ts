// bun test/multi.ts — one nvim, several agents (exact cwd, ancestor cwd, unrelated cwd).
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynom-"));
const rt = path.join(tmp, "rt"), proj = path.join(tmp, "proj"), other = path.join(tmp, "elsewhere");
for (const d of [proj, other]) fs.mkdirSync(d);
for (const [d, f] of [[proj, "a.txt"], [proj, "b.txt"], [tmp, "c.txt"], [other, "d.txt"]]) fs.writeFileSync(path.join(d, f), "alpha\nbeta\n");
const planFile = path.join(tmp, "plan.json");
fs.writeFileSync(planFile, JSON.stringify({ seq: ["accept_all", "reject_all"] })); // 1st review accepted, 2nd rejected
const log = path.join(tmp, "nvim.log");

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

const nvim = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile " + root + "/test/nvim_driver.lua", path.join(proj, "a.txt")], {
  cwd: proj, env: { ...process.env, RYNO_DIR: rt, RYNO_ROOT: root, RYNO_PLAN_FILE: planFile, RYNO_LOG: log }, stdio: "ignore",
});
await Bun.sleep(500);

const child = (cwd: string, file: string, delay = 0) => new Promise<any>((res) => {
  const p = spawn("bun", [path.join(root, "test/agent_child.ts")], { env: { ...process.env, RYNO_DIR: rt, CHILD_CWD: cwd, CHILD_FILE: file, CHILD_DELAY: String(delay) }, stdio: ["ignore", "pipe", "inherit"] });
  let out = ""; p.stdout.on("data", (d) => (out += d)); p.on("exit", () => res(out.trim() ? JSON.parse(out) : null));
});

// A: cwd == nvim cwd.  B: ancestor of nvim cwd (the zombie-worker case).  X: unrelated cwd, must NOT be reviewed.
const [A, B, X] = await Promise.all([child(proj, "b.txt", 5000), child(tmp, "c.txt", 5000), child(other, "d.txt", 5000)]);
const reviewed = fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((o) => o.ev === "review");

console.log("results:", JSON.stringify({ A, B, X }));
ok(X && !X.blocked, "unrelated agent: not reviewed, edit proceeded unasked");
ok(A && B, "both matching agents got an answer (no hang => decisions routed to the right agent)");
ok(reviewed.length === 2, "nvim reviewed exactly the 2 matching agents' edits: " + reviewed.length);
ok([A, B].filter((r) => r.blocked).length === 1 && [A, B].filter((r) => !r.blocked).length === 1, "one accepted + one rejected, each to its own agent");
nvim.kill();
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
