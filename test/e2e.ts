// bun test/e2e.ts  — drives the real extension + a headless nvim running the real plugin.
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.mkdtempSync(path.join("/tmp", "rynot-"));
const dirRt = path.join(tmp, "rt");
process.env.RYNO_DIR = dirRt;
process.env.RYNO_BASH = "review"; // independent of ~/.config/ryno/settings.json
const work = path.join(tmp, "proj"); fs.mkdirSync(work);
const log = path.join(tmp, "nvim.log");

const handlers: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h) } as any);
const ctx = { cwd: work, ui: {}, sessionManager: { getSessionId: () => "sess" }, signal: undefined };
await handlers.session_start({}, ctx);

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };
const read = (f: string) => fs.readFileSync(path.join(work, f), "utf8");

const A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
fs.writeFileSync(path.join(work, "a.txt"), A);
fs.writeFileSync(path.join(work, "b.txt"), A);
fs.writeFileSync(path.join(work, "c.txt"), A);
fs.writeFileSync(path.join(work, "crlf.txt"), "x\r\ny\r\nz\r\n");
const edits2 = [{ oldText: "two", newText: "TWO" }, { oldText: "six", newText: "SIX\nSIX2" }];

const plan = { t_accept: "accept_all", t_reject: "reject_all", t_partial: "partial", t_new: "accept_all", t_crlf: "partial", t_each: "each", t_after: "accept_all" };
const nvim = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set noswapfile", "-c", `luafile ${root}/test/nvim_driver.lua`, path.join(work, "a.txt")], {
  cwd: work, env: { ...process.env, RYNO_ROOT: root, RYNO_PLAN: JSON.stringify(plan), RYNO_LOG: log }, stdio: "ignore",
});

// wait for connection
for (let i = 0; i < 100 && !(await Bun.file(path.join(dirRt, `${process.pid}.sock`)).exists()); i++) await Bun.sleep(50);
await Bun.sleep(800); // nvim poll connects

const call = (id: string, tool: string, input: any) => handlers.tool_call({ toolName: tool, toolCallId: id, input }, ctx);
const applied = async (id: string, input: any, tool: string) => handlers.tool_result({ toolName: tool, toolCallId: id, input, isError: false });

console.log("accept all (edit, 2 hunks)");
let r = await call("t_accept", "edit", { path: "a.txt", edits: edits2 });
ok(r === undefined, "tool allowed");
fs.writeFileSync(path.join(work, "a.txt"), "one\nTWO\nthree\nfour\nfive\nSIX\nSIX2\nseven\n"); // what the tool would do
await applied("t_accept", { path: "a.txt" }, "edit");
await Bun.sleep(300);

console.log("reject all");
r = await call("t_reject", "edit", { path: "b.txt", edits: edits2 });
ok(r?.block === true && /rejected/.test(r.reason), "tool blocked: " + r?.reason?.slice(0, 50));
ok(read("b.txt") === A, "file untouched");

console.log("partial (accept hunk 1, reject rest)");
r = await call("t_partial", "edit", { path: "c.txt", edits: edits2 });
ok(r?.block === true && /accepted only 1 of 2/.test(r.reason), "blocked w/ partial note");
ok(/near line 6: wanted to replace "six" with "SIX\\nSIX2"/.test(r.reason), "reason names rejected hunk: " + r.reason.split("\n")[1]);
ok(read("c.txt") === "one\nTWO\nthree\nfour\nfive\nsix\nseven\n", "only first hunk on disk: " + JSON.stringify(read("c.txt")));

console.log("write new file");
r = await call("t_new", "write", { path: "sub/new.txt", content: "hello\nworld\n" });
ok(r === undefined, "new-file write allowed");

console.log("partial on CRLF file keeps CRLF");
r = await call("t_crlf", "write", { path: "crlf.txt", content: "X\r\ny\r\nZ\r\n" });
ok(r?.block === true, "blocked");
ok(read("crlf.txt") === "X\r\ny\r\nz\r\n", "crlf preserved: " + JSON.stringify(read("crlf.txt")));

console.log("accept hunks one-by-one");
fs.writeFileSync(path.join(work, "d.txt"), A);
plan.t_each; r = await call("t_each", "edit", { path: "d.txt", edits: edits2 });
ok(r === undefined, "all hunks accepted individually -> allowed");

console.log("unmatched edit passes through");
r = await call("t_none", "edit", { path: "d.txt", edits: [{ oldText: "nope", newText: "x" }] });
ok(r === undefined, "left for the tool to report");

console.log("session replaced in the same process (/new): fresh extension instance must be reviewed too");
const h2: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (h2[n] = h) } as any); // factory runs again; old instance is NOT told to shut down
await h2.session_start({}, ctx);
await Bun.sleep(1500); // nvim notices the new socket and reconnects
r = await h2.tool_call({ toolName: "edit", toolCallId: "t_after", input: { path: "d.txt", edits: edits2 } }, ctx);
ok(r === undefined, "second instance: edit allowed after review");
await Bun.sleep(300);

console.log("no editor connected -> policy");
nvim.kill(); await Bun.sleep(300);
r = await h2.tool_call({ toolName: "edit", toolCallId: "t_off", input: { path: "d.txt", edits: edits2 } }, ctx); //, { path: "d.txt", edits: edits2 });
ok(r === undefined, "allow by default");
process.env.RYNO_NO_EDITOR = "block";
r = await h2.tool_call({ toolName: "edit", toolCallId: "t_off2", input: { path: "d.txt", edits: edits2 } }, ctx); //, { path: "d.txt", edits: edits2 });
ok(r?.block === true, "block when RYNO_NO_EDITOR=block");

await h2.session_shutdown({ reason: "quit" });

console.log("\nnvim observations:");
const obs = fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
for (const o of obs) console.log("  ", JSON.stringify(o));
const ap = obs.find((o) => o.ev === "applied" && o.id === "t_accept");
ok(ap?.text === "one|TWO|three|four|five|SIX|SIX2|seven" && ap?.modifiable === true && ap?.winbar === "", "buffer reloaded after applied, unlocked, winbar restored: " + ap?.text);
const rv = (id: string) => obs.find((o) => o.ev === "review" && o.id === id);
ok(rv("t_accept")?.hunks === 2 && rv("t_accept")?.virt_lines === 2 && rv("t_accept")?.scratch === true, "review buffer shows real proposed lines plus removed-line virtual text");
ok(rv("t_accept")?.buftext.includes("TWO") && rv("t_accept")?.buftext.includes("SIX2"), "long proposed sections are real cursorable buffer lines");
ok(rv("t_accept")?.modifiable === false, "buffer locked during review");
ok(rv("t_after")?.hunks === 2, "nvim showed the review for the replaced session (the /new bug)");
ok(rv("t_new")?.scratch === true, "new file reviewed in scratch");
console.log(failed ? `\n${failed} FAILED` : "\nALL OK");
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
