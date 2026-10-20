// bun test/bash_e2e.ts — changes made by `bash` (applied first, then reviewed / rolled back).
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynob-"));
const rt = path.join(tmp, "rt"), work = path.join(tmp, "proj"), planFile = path.join(tmp, "plan.json"), log = path.join(tmp, "nvim.log");
fs.mkdirSync(work);
process.env.RYNO_DIR = rt;
process.env.RYNO_BASH = "review"; // independent of ~/.config/ryno/settings.json

const sh = (cmd: string) => spawnSync("sh", ["-c", cmd], { cwd: work, encoding: "utf8" });
const w = (f: string, t: string) => { fs.mkdirSync(path.dirname(path.join(work, f)), { recursive: true }); fs.writeFileSync(path.join(work, f), t); };
const r = (f: string) => fs.readFileSync(path.join(work, f), "utf8");
const exists = (f: string) => fs.existsSync(path.join(work, f));
const A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
w("a.txt", A); w("b.txt", A); w("c.txt", A); w("d.txt", A); w(".gitignore", "ignored/\n");
sh("git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init");

const plan = (seq: string[]) => fs.writeFileSync(planFile, JSON.stringify({ seq }));
plan([]);

const handlers: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h) } as any);
const ctx = { cwd: work, ui: {}, sessionManager: { getSessionId: () => "s" }, signal: undefined };
await handlers.session_start({}, ctx);

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

const nvim = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile " + root + "/test/nvim_driver.lua", path.join(work, "a.txt")], {
  cwd: work, env: { ...process.env, RYNO_DIR: rt, RYNO_ROOT: root, RYNO_PLAN_FILE: planFile, RYNO_LOG: log }, stdio: "ignore",
});
await Bun.sleep(1500);

let n = 0;
/** run a "bash command": snapshot hook -> the command's effect on disk -> result hook */
async function bash(effect: () => void) {
  const id = "bash-" + ++n;
  await handlers.tool_call({ toolName: "bash", toolCallId: id, input: { command: "…" } }, ctx);
  effect();
  return handlers.tool_result({ toolName: "bash", toolCallId: id, input: { command: "…" }, content: [{ type: "text", text: "command output" }], isError: false }, ctx);
}
const text = (res: any) => (res?.content ?? []).map((c: any) => c.text).join("\n");
const reviews = () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((o) => o.ev === "review") : []);

console.log("reject -> the file is rolled back");
plan(["reject_all"]);
let res = await bash(() => w("a.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\n"));
ok(r("a.txt") === A, "a.txt restored: " + JSON.stringify(r("a.txt")));
ok(/ROLLED BACK[^]*a\.txt/.test(text(res)) && text(res).startsWith("command output"), "agent told, original output kept: " + text(res).slice(0, 150).replace(/\n/g, " | "));

console.log("accept -> kept, nothing rolled back");
plan(["accept_all"]);
res = await bash(() => w("b.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\n"));
ok(r("b.txt").includes("TWO"), "b.txt keeps the change");
ok(/kept: b\.txt/.test(text(res)) && !/ROLLED BACK/.test(text(res)), "reported as kept: " + text(res).split("\n").pop()?.slice(0, 90));

console.log("partial -> only accepted hunks survive");
plan(["partial"]); // driver: accept first hunk, reject the rest
res = await bash(() => w("c.txt", "ONE\ntwo\nthree\nfour\nfive\nSIX\nseven\n"));
ok(r("c.txt") === "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\n", "first hunk kept, second rolled back: " + JSON.stringify(r("c.txt")));
ok(/PARTIALLY kept/.test(text(res)), "reported as partial");

console.log("new file created by the command -> rejecting deletes it");
plan(["reject_all"]);
res = await bash(() => w("src/new.zig", "pub fn main() void {}\n"));
ok(!exists("src/new.zig"), "new file deleted");
ok(/new file deleted/.test(text(res)), "reported");

console.log("deleted file -> rejecting restores it");
plan(["reject_all"]);
res = await bash(() => fs.unlinkSync(path.join(work, "d.txt")));
ok(r("d.txt") === A, "d.txt restored");

console.log("file that was ALREADY dirty: rollback goes to the pre-command state, not to git's");
w("a.txt", "mine\nline\n"); // user's unsaved-to-git work
plan(["reject_all"]);
res = await bash(() => w("a.txt", "mine\nline\nagent added\n"));
ok(r("a.txt") === "mine\nline\n", "restored to the user's pre-command content: " + JSON.stringify(r("a.txt")));

console.log("no-op command / ignored output / unchanged dirty file -> no review, result untouched");
const before = reviews().length;
res = await bash(() => { w("ignored/out.bin", "x"); });
ok(res === undefined && reviews().length === before, "nothing to review");

console.log("command run twice on identical content is not a change");
res = await bash(() => w("b.txt", r("b.txt")));
ok(res === undefined, "same content -> no review");

console.log("edit/write interception unaffected");
plan(["accept_all"]);
const e = await handlers.tool_call({ toolName: "edit", toolCallId: "e1", input: { path: "b.txt", edits: [{ oldText: "three", newText: "3" }] } }, ctx);
ok(e === undefined, "edit still reviewed and allowed");

console.log("too many changed files -> not reviewed, agent told");
res = await bash(() => { for (let i = 0; i < 25; i++) w(`gen/f${i}.txt`, "x\n"); });
ok(/too many to review/.test(text(res)) && exists("gen/f0.txt"), "left as is, with a note");

nvim.kill();
await handlers.session_shutdown({ reason: "quit" });
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
