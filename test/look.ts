// bun test/look.ts [file] — show what a review looks like in real nvim (your config) inside tmux, print the screen.
// Not an assertion test: a visual harness. Uses a copy of a real file with a multi-hunk edit.
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const src = process.argv[2] ?? "/Users/max/ml/pihole/zig/src/message/name.zig";
const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynolook-"));
const rt = path.join(tmp, "rt");
process.env.RYNO_DIR = rt;
const file = path.join(tmp, path.basename(src));
fs.copyFileSync(src, file);
const text = fs.readFileSync(file, "utf8");

const handlers: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h) } as any);
const ctx = { cwd: tmp, ui: {}, sessionManager: { getSessionId: () => "s" }, signal: undefined };
await handlers.session_start({}, ctx);

const S = "RYNOLOOK";
const tm = (...a: string[]) => spawnSync("tmux", a, { encoding: "utf8" });
tm("kill-session", "-t", S);
tm("new-session", "-d", "-x", "130", "-y", "42", "-s", S, "-c", tmp, `env RYNO_DIR=${rt} nvim --listen ${tmp}/nvim.sock ${file}`);
await Bun.sleep(5000); // user config + poll connect

// edits: a modified line (intra-line change), a pure insertion, a pure deletion
const lines = text.split("\n");
const pick = (re: RegExp) => lines.find((l) => re.test(l))!;
const e1 = pick(/const /), e2 = pick(/fn |pub fn /), e3 = lines.filter((l) => l.trim().startsWith("//") || l.trim() === "}")[0];
const edits = [
  { oldText: e1, newText: e1.replace(/const (\w+)/, "const renamed_$1") },
  { oldText: e2, newText: "// new helper added by the agent\n// second line\n" + e2 },
  ...(e3 && e3 !== e1 && e3 !== e2 ? [{ oldText: e3 + "\n", newText: "" }] : []),
];
const p = handlers.tool_call({ toolName: "edit", toolCallId: "look", input: { path: file, edits } }, ctx);
await Bun.sleep(1800);
console.log(tm("capture-pane", "-p", "-t", S).stdout.replace(/\n+$/, ""));
if (process.env.LOOK_DEBUG) {
  const q0 = (expr: string) => spawnSync("nvim", ["--server", tmp + "/nvim.sock", "--remote-expr", expr], { encoding: "utf8" }).stdout;
  for (const g of ["Normal", "DiffAdd", "RynoAdd", "RynoAddText", "DiffDelete", "RynoDelete", "RynoDeleteText", "DiffText", "DiffChange", "Added", "DiffAdded", "WinBar"])
    console.log(g, q0(`luaeval("vim.inspect(vim.api.nvim_get_hl(0,{name='${g}',link=false}))")`).replace(/\s+/g, " "));
  const q = (expr: string) => spawnSync("nvim", ["--server", tmp + "/nvim.sock", "--remote-expr", expr], { encoding: "utf8" }).stdout;
  console.log("extmarks row0:", q(`luaeval("vim.inspect(vim.tbl_map(function(m) return {m[3], m[4].end_col, m[4].hl_group, m[4].line_hl_group} end, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('ryno'), {0,0}, {0,-1}, {details=true})))")`).replace(/\s+/g, " "));
  console.log("lsp clients:", q(`luaeval("vim.inspect(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({bufnr=require('ryno.review').active.buf})))")`).replace(/\s+/g, " "));
  console.log("syntax buffers:", q(`luaeval("vim.inspect({new=require('ryno.review').active and vim.bo[require('ryno.review').active.buf].filetype, old=require('ryno.review').active and vim.bo[require('ryno.review').active.syntax_buf].filetype, pos=vim.inspect_pos(require('ryno.review').active.syntax_buf, 10, 4), marks=vim.api.nvim_buf_get_extmarks(require('ryno.review').active.buf, vim.api.nvim_create_namespace('ryno'), 0, -1, {details=true})})")`).replace(/\s+/g, " "));
  console.log("winbar option:", q("&winbar"));
  console.log("eval:", q(`luaeval("vim.inspect(vim.api.nvim_eval_statusline(vim.wo.winbar, {winid=0, use_winbar=true, maxwidth=130}))")`));
  console.log("active win vs current:", q(`luaeval("tostring(require('ryno.review').active and require('ryno.review').active.win)..' '..vim.api.nvim_get_current_win()")`));
}
if (process.env.LOOK_ANSI) fs.writeFileSync("/tmp/look.ansi", tm("capture-pane", "-e", "-p", "-t", S).stdout);
tm("send-keys", "-t", S, "Space", "i", "r"); // reject so the harness exits cleanly
await Promise.race([p, Bun.sleep(3000)]);
tm("kill-session", "-t", S);
await handlers.session_shutdown({ reason: "quit" });
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(0);
