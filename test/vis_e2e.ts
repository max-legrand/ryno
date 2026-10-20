// bun test/vis_e2e.ts — real vis in tmux + real extension (mock host).
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const root = path.resolve(import.meta.dir, "..");
const tmp = fs.mkdtempSync("/tmp/rynov-");
const rt = path.join(tmp, "rt"), work = path.join(tmp, "proj"), cfgHome = path.join(tmp, "cfg"), cfg = path.join(cfgHome, "vis");
fs.mkdirSync(work); fs.mkdirSync(path.join(cfg, "plugins"), { recursive: true });
fs.symlinkSync(path.join(root, "vis/ryno"), path.join(cfg, "plugins/ryno"));
fs.writeFileSync(path.join(cfg, "visrc.lua"), 'require("vis")\nrequire("plugins/ryno")\n');
process.env.RYNO_DIR = rt;

const handlers: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h) } as any);
const ctx = { cwd: work, ui: {}, sessionManager: { getSessionId: () => "s" }, signal: undefined };
await handlers.session_start({}, ctx);

fs.writeFileSync(path.join(work, "f.txt"), "one\ntwo\nthree\n");
const S = "RYNO_VIS_T";
const tm = (...a: string[]) => spawnSync("tmux", a, { encoding: "utf8" });
const screen = () => tm("capture-pane", "-p", "-t", S).stdout;
tm("kill-session", "-t", S);
tm("new-session", "-d", "-x", "110", "-y", "30", "-s", S, "-c", work,
  "env XDG_CONFIG_HOME=" + cfgHome + " HOME=" + tmp + " RYNO_DIR=" + rt + " PWD=" + work + " vis f.txt");

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };
const lim = <T,>(p: Promise<T>, ms = 6000) => Promise.race([p, Bun.sleep(ms).then(() => "TIMEOUT" as any)]);
const wait = async (pred: () => boolean, ms = 6000) => { for (let t = 0; t < ms && !pred(); t += 100) await Bun.sleep(100); return pred(); };

await Bun.sleep(1000);
tm("send-keys", "-t", S, ":ryno-status", "Enter");
ok(await wait(() => /connected to .* pid/.test(screen())), "vis auto-connected to extension via nc bridge");
if (failed) console.log(screen());

const p1 = handlers.tool_call({ toolName: "edit", toolCallId: "v1", input: { path: "f.txt", edits: [{ oldText: "two", newText: "TWO" }] } }, ctx);
ok(await wait(() => /\+TWO/.test(screen())), "unified diff shown in vis");
console.log(screen());
tm("send-keys", "-t", S, ":ryno-accept", "Enter");
ok((await lim(p1)) === undefined, "accept -> tool allowed");

const p2 = handlers.tool_call({ toolName: "edit", toolCallId: "v2", input: { path: "f.txt", edits: [{ oldText: "three", newText: "3" }] } }, ctx);
ok(await wait(() => /\+3/.test(screen())), "second review shown");
tm("send-keys", "-t", S, ":ryno-reject too risky", "Enter");
const r2: any = await lim(p2);
ok(r2?.block === true && /too risky/.test(r2.reason), "reject w/ reason -> blocked: " + r2?.reason?.slice(0, 90));

// simulate the tool writing, then the `applied` notification
fs.writeFileSync(path.join(work, "f.txt"), "one\nTWO\nthree\n");
await handlers.tool_result({ toolName: "edit", toolCallId: "v1", input: { path: "f.txt" }, isError: false });
ok(await wait(() => /TWO/.test(screen())), "buffer reloaded after applied");
console.log(screen());

tm("kill-session", "-t", S);
await handlers.session_shutdown({ reason: "quit" });
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
