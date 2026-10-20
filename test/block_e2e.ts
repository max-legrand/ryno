// bun test/block_e2e.ts — RYNO_BASH=block: bash may not change project files (real commands, real sandbox).
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import ryno, { BLOCK_PROMPT } from "../extension/ryno.ts";

const tmp = fs.realpathSync(fs.mkdtempSync("/tmp/rynoblk-"));
process.env.RYNO_DIR = path.join(tmp, "rt");
process.env.RYNO_BASH = "block";

let failed = 0;
const ok = (c: any, m: string) => { if (!c) { failed++; console.log("  FAIL", m); } else console.log("  ok  ", m); };

function repo(name: string, commit: boolean) {
  const w = path.join(tmp, name);
  fs.mkdirSync(path.join(w, "src"), { recursive: true });
  fs.writeFileSync(path.join(w, "src/name.zig"), "fn parseName() void {\n    old();\n}\n");
  fs.writeFileSync(path.join(w, ".gitignore"), ".zig-cache/\nzig-out/\n");
  spawnSync("sh", ["-c", "git init -q" + (commit ? " && git add -A && git -c user.name=t -c user.email=t@t commit -qm i" : "")], { cwd: w });
  return w;
}

const handlers: Record<string, Function> = {};
const commands: Record<string, any> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h), registerCommand: (n: string, c: any) => (commands[n] = c) } as any);

let n = 0;
/** what pi does: tool_call (may mutate input) -> run input.command with bash in cwd -> tool_result */
async function bash(cwd: string, command: string, during?: () => void) {
  const ctx = { cwd, ui: {}, sessionManager: { getSessionId: () => "s" } };
  const input = { command };
  const id = "b" + ++n;
  await handlers.tool_call({ toolName: "bash", toolCallId: id, input }, ctx);
  const wrapped = input.command !== command;
  let r: ReturnType<typeof spawnSync>;
  if (during) {
    const p = Bun.spawn(["bash", "-c", input.command], { cwd, stdout: "pipe", stderr: "pipe" });
    await Bun.sleep(150); during();
    await p.exited;
    r = { stdout: await new Response(p.stdout).text(), stderr: await new Response(p.stderr).text(), status: p.exitCode } as any;
  } else r = spawnSync("bash", ["-c", input.command], { cwd, encoding: "utf8" });
  const content = [{ type: "text", text: String(r.stdout) + String(r.stderr) }];
  const res = await handlers.tool_result({ toolName: "bash", toolCallId: id, input, content, isError: r.status !== 0 }, ctx);
  return { wrapped, out: content[0].text, note: (res?.content ?? []).slice(1).map((c: any) => c.text).join("\n"), status: r.status };
}

const W = repo("proj", true);
await handlers.session_start({}, { cwd: W, ui: {}, sessionManager: { getSessionId: () => "s" } });
const read = (f: string, w = W) => fs.readFileSync(path.join(w, f), "utf8");
const ORIG = "fn parseName() void {\n    old();\n}\n";

console.log("python heredoc rewrite (your example) is refused up front");
let r = await bash(W, `python3 - <<'PY'\np='src/name.zig'\ns=open(p).read()\nopen(p,'w').write(s.replace('old()','new_impl()'))\nPY`);
ok(r.wrapped, "command was sandboxed");
ok(read("src/name.zig") === ORIG, "file untouched");
ok(/Operation not permitted/.test(r.out) && /expected/.test(r.note) && /edit\/write tools/.test(r.note), "agent told why + what to do: " + r.note.slice(0, 120));

console.log("sed -i, mv over, rm, > redirect");
for (const c of ["sed -i '' s/old/x/ src/name.zig", "echo x > /tmp/ryno_mv_$$ && mv /tmp/ryno_mv_$$ src/name.zig", "rm src/name.zig", "echo x > src/name.zig", "echo x >> src/name.zig"]) {
  r = await bash(W, c);
  ok(read("src/name.zig") === ORIG, "untouched after: " + c);
}

console.log("new file via heredoc -> deleted afterwards");
r = await bash(W, "cat > src/helper.zig <<'EOF2'\npub fn h() void {}\nEOF2");
ok(!fs.existsSync(path.join(W, "src/helper.zig")), "new file removed");
ok(/REVERTED: src\/helper\.zig \(new file, deleted\)/.test(r.note), "reported: " + r.note.slice(0, 100));

console.log("builds/tests keep working: reads, ignored caches, temp files");
r = await bash(W, "cat src/name.zig >/dev/null && mkdir -p .zig-cache zig-out && echo c > .zig-cache/x && echo o > zig-out/bin && echo t > /tmp/ryno_t_$$ && echo done");
ok(r.status === 0 && /done/.test(r.out) && r.note === "", "succeeds silently");
ok(read(".zig-cache/x") === "c\n", "ignored cache written");

console.log("setuid read-only tools (ps) still run; sudo does not");
r = await bash(W, "ps -o pid= -p $$ >/dev/null && echo PS_OK; sudo -n true 2>&1 | head -1");
ok(/PS_OK/.test(r.out), "ps works under the sandbox");
ok(/sudo: Operation not permitted/.test(r.out), "sudo stays blocked");

console.log("the user saving a file in the editor during a command is NOT reverted");
r = await bash(W, "sleep 0.6", () => fs.writeFileSync(path.join(W, "src/name.zig"), ORIG + "// user\n"));
ok(read("src/name.zig") === ORIG + "// user\n", "user's save kept");
fs.writeFileSync(path.join(W, "src/name.zig"), ORIG);

console.log("repo without commits (like ~/ml/pihole): untracked files are protected too");
const P = repo("nocommit", false);
r = await bash(P, "sed -i '' s/old/x/ src/name.zig");
ok(r.wrapped && read("src/name.zig", P) === ORIG, "untouched");

console.log("edit/write tools are unaffected (no editor connected -> allowed as usual)");
const e = await handlers.tool_call({ toolName: "edit", toolCallId: "e", input: { path: "src/name.zig", edits: [{ oldText: "old", newText: "new" }] } }, { cwd: W, ui: {} });
ok(e === undefined, "edit allowed");

console.log("system prompt tells the agent up front");
const sp = await handlers.before_agent_start({ systemPrompt: "BASE" });
ok(sp?.systemPrompt === "BASE\n\n" + BLOCK_PROMPT, "appended");

console.log("no sandbox available -> change happens, then is reverted");
process.env.RYNO_SANDBOX = "off";
r = await bash(W, "sed -i '' s/old/x/ src/name.zig");
ok(!r.wrapped && read("src/name.zig") === ORIG && /REVERTED: src\/name\.zig/.test(r.note), "reverted: " + r.note.slice(0, 90));
delete process.env.RYNO_SANDBOX;

console.log("/ryno-bash switches modes for the session");
const notes: string[] = [];
await commands["ryno-bash"].handler("off", { ui: { notify: (m: string) => notes.push(m) } });
r = await bash(W, "sed -i '' s/old/x/ src/name.zig");
ok(!r.wrapped && read("src/name.zig").includes("x()") && /mode: off/.test(notes[0]), "off: bash unrestricted");
ok((await handlers.before_agent_start({ systemPrompt: "BASE" })) === undefined, "off: no prompt change");
fs.writeFileSync(path.join(W, "src/name.zig"), ORIG);

await handlers.session_shutdown({ reason: "quit" });
ok(!fs.readdirSync(path.join(tmp, "rt")).some((f) => f.endsWith(".sb")), "sandbox profiles cleaned up");
console.log(failed ? "\n" + failed + " FAILED" : "\nALL OK");
if (!failed) fs.rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
