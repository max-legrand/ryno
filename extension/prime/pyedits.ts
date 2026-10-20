/**
 * Static extraction of `await edit(path=…, old_str=…, new_str=…)` calls from a prime-agent
 * `ipython` cell, so the file changes can be reviewed before the cell runs.
 *
 * Best effort by design: only top-level (not in loops/ifs/functions/try) calls whose arguments
 * resolve to string literals — directly or through simple top-level `name = "literal"` bindings,
 * `+` concatenation and f-strings of those — are reviewed. Anything computed at runtime
 * (`old = content[a:b]`) is invisible here and passes through unreviewed.
 */
import { spawnSync } from "node:child_process";
import * as os from "node:os";
import * as path from "node:path";
import { readDisk } from "../ryno.ts";

const PY = String.raw`
import ast, json, sys

code = sys.stdin.read()
try:
    tree = compile(code, "<cell>", "exec", flags=ast.PyCF_ONLY_AST | getattr(ast, "PyCF_ALLOW_TOP_LEVEL_AWAIT", 0))
except Exception:
    print(json.dumps({"ok": False}))
    sys.exit(0)

UNK = object()
env = {}
calls = []
CONTROL = tuple(
    getattr(ast, n)
    for n in ("For", "AsyncFor", "While", "If", "Try", "TryStar", "Match", "FunctionDef",
              "AsyncFunctionDef", "ClassDef", "Lambda", "ListComp", "SetComp", "DictComp", "GeneratorExp")
    if hasattr(ast, n)
)

def ev(n):
    if isinstance(n, ast.Constant):
        return n.value if isinstance(n.value, str) else UNK
    if isinstance(n, ast.Name):
        return env.get(n.id, UNK)
    if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
        a, b = ev(n.left), ev(n.right)
        return a + b if isinstance(a, str) and isinstance(b, str) else UNK
    if isinstance(n, ast.JoinedStr):
        out = []
        for v in n.values:
            if isinstance(v, ast.Constant) and isinstance(v.value, str):
                out.append(v.value)
            elif isinstance(v, ast.FormattedValue) and v.conversion == -1 and v.format_spec is None:
                s = ev(v.value)
                if not isinstance(s, str):
                    return UNK
                out.append(s)
            else:
                return UNK
        return "".join(out)
    return UNK

def kill_names(node):
    for n in ast.walk(node):
        if isinstance(n, ast.Name) and isinstance(n.ctx, (ast.Store, ast.Del)):
            env[n.id] = UNK

NAMES = ["path", "old_str", "new_str"]

def find_calls(node, dyn):
    dyn = dyn or isinstance(node, CONTROL)
    for child in ast.iter_child_nodes(node):
        find_calls(child, dyn)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "edit":
        if dyn:
            calls.append({"unresolved": True})
            return
        a = {}
        for i, x in enumerate(node.args[:3]):
            a[NAMES[i]] = ev(x)
        for k in node.keywords:
            if k.arg in NAMES:
                a[k.arg] = ev(k.value)
        if all(isinstance(a.get(k), str) for k in NAMES):
            calls.append({"path": a["path"], "old": a["old_str"], "new": a["new_str"]})
        else:
            calls.append({"unresolved": True})

for stmt in tree.body:
    find_calls(stmt, False)
    if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
        env[stmt.targets[0].id] = ev(stmt.value)
    else:
        kill_names(stmt)

print(json.dumps({"ok": True, "calls": calls}))
`;

export type EditCall = { path: string; old: string; new: string } | { unresolved: true };

export function extractEditCalls(code: string): EditCall[] | null {
	if (!/\bedit\s*\(/.test(code)) return [];
	const r = spawnSync("python3", ["-c", PY], { input: code, encoding: "utf8", timeout: 5000, maxBuffer: 64 << 20 });
	if (r.status !== 0 || !r.stdout) return null;
	try {
		const j = JSON.parse(r.stdout);
		return j.ok ? j.calls : null;
	} catch {
		return null;
	}
}

export interface FileChange {
	abs: string;
	original: string;
	final: string;
	edits: number;
}

/**
 * Replay the calls in order against the files as they are now, with the REPL `edit` semantics:
 * `old_str` must occur exactly once in the (newline-normalised) content, else the cell raises there.
 * Replay stops at the first call that is unresolved or would raise.
 */
export function simulate(calls: EditCall[], cwd: string): { changes: FileChange[]; complete: boolean } {
	const files = new Map<string, FileChange>();
	let complete = true;
	for (const c of calls) {
		if ("unresolved" in c) { complete = false; break; }
		let p = c.path;
		if (p === "~" || p.startsWith("~/")) p = path.join(os.homedir(), p.slice(1));
		const abs = path.resolve(cwd, p);
		let f = files.get(abs);
		if (!f) {
			const d = readDisk(abs);
			if (!d) { complete = false; break; } // FileNotFoundError at runtime
			f = { abs, original: d.text, final: d.text, edits: 0 };
			files.set(abs, f);
		}
		const first = f.final.indexOf(c.old);
		if (c.old === "" || first < 0 || f.final.indexOf(c.old, first + c.old.length) >= 0 /* str.count() is non-overlapping */) { complete = false; break; }
		f.final = f.final.slice(0, first) + c.new + f.final.slice(first + c.old.length);
		f.edits++;
	}
	return { changes: [...files.values()].filter((f) => f.final !== f.original), complete };
}
