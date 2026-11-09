// Real Pi tool -> socket -> Neovim comments, with review-only enforcement enabled.
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const root = process.cwd();
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/ryno-findings-"));
const file = path.join(tmp, "source.txt"), socket = path.join(tmp, "nvim.sock");
fs.writeFileSync(file, "one\ntwo\nthree\n");
process.env.RYNO_DIR = path.join(tmp, "rt");
process.env.RYNO_SETTINGS = "/nonexistent/ryno-settings.json";
process.env.RYNO_MODE = "review";
const handlers: Record<string, Function> = {}, tools: Record<string, any> = {};
const ctx = { cwd: tmp, ui: { setStatus() {} }, sessionManager: { getSessionId: () => "findings" } };
ryno({
  on: (name: string, fn: Function) => handlers[name] = fn,
  registerTool: (tool: any) => tools[tool.name] = tool,
} as any);
await handlers.session_start({}, ctx);
const editor = spawn("nvim", ["--headless", "--listen", socket, "-u", "NONE", "-i", "NONE",
  "--cmd", "set noswapfile", "--cmd", `lua vim.opt.rtp:prepend(${JSON.stringify(root)})`,
  "-c", "runtime plugin/ryno.lua", "-c", "lua require('ryno').setup({poll_ms=50,focus_pane=false})", file],
  { cwd: tmp, env: process.env, stdio: "ignore" });
const expr = (lua: string) => {
  const r = spawnSync("nvim", ["--server", socket, "--remote-expr", `luaeval(${JSON.stringify(lua)})`], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
};
async function wait(check: () => boolean) {
  for (let i = 0; i < 100; i++) { if (check()) return; await Bun.sleep(50); }
  throw new Error("Timed out waiting for Neovim");
}
const assert = (ok: boolean, msg: string) => { if (!ok) throw new Error(msg); console.log("ok:", msg); };
try {
  await wait(() => (globalThis as any).__rynoApi.hasEditors());
  const input = { findings: [{ path: "source.txt", line: 2, title: "Combine arrivals", body: "Count arrivals per node. Verify with a diamond graph." }] };
  assert(await handlers.tool_call({ toolName: "ryno_findings", input }, ctx) === undefined, "findings allowed in review mode");
  await tools.ryno_findings.execute("f", input, undefined, undefined, ctx);
  await wait(() => expr("#require('ryno.findings').get(0)") === "1");
  assert(expr("require('ryno.findings').get(0)[1].message").includes("Combine arrivals"), "finding rendered in real Neovim");
  assert(expr("require('ryno.findings').get(0)[1].lnum") === "1", "comment anchored to source line 2");
  assert(expr("#vim.diagnostic.get(0)") === "0", "reviews do not participate in diagnostic navigation");
  assert(expr("tostring(vim.bo.modified)") === "false", "source buffer is not modified");
  assert(fs.readFileSync(file, "utf8") === "one\ntwo\nthree\n", "source file is unchanged");
  assert((await handlers.tool_call({ toolName: "write", input: {} }, ctx))?.block, "file writes remain blocked");
  await tools.ryno_findings.execute("f", { findings: [] }, undefined, undefined, ctx);
  await wait(() => expr("#require('ryno.findings').get(0)") === "0");
  console.log("ALL OK: review-only findings delivered to Neovim");
} finally {
  editor.kill();
  await handlers.session_shutdown({});
}
