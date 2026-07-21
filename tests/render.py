#!/usr/bin/env python3
"""
Minimal Go-template renderer covering ONLY the constructs used by this chart.
Fallback for environments without a helm binary — CI runs real `helm template`
and is authoritative. Usage:
  python3 tests/render.py [--set key=value ...] > rendered.yaml
"""
import re, sys, json, os
import yaml

CHART_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load_values(sets):
    with open(os.path.join(CHART_DIR, "values.yaml")) as f:
        values = yaml.safe_load(f)
    for kv in sets:
        key, _, val = kv.partition("=")
        cur = values
        parts = key.split(".")

        def descend(container, part, make):
            """Handle both plain keys and list indices like name[0]."""
            m = re.match(r"^([^\[]+)\[(\d+)\]$", part)
            if not m:
                if isinstance(container, dict):
                    if make and part not in container:
                        container[part] = {}
                    return container, part
                return container, part
            name, idx = m.group(1), int(m.group(2))
            lst = container.setdefault(name, [])
            if not isinstance(lst, list):
                lst = []
                container[name] = lst
            while len(lst) <= idx:
                lst.append({})
            return lst, idx

        for p in parts[:-1]:
            cur, k = descend(cur, p, True)
            cur = cur[k]
        if val in ("true", "false"):
            v = val == "true"
        elif re.fullmatch(r"-?\d+", val):
            v = int(val)
        else:
            v = val
        cur, k = descend(cur, parts[-1], False)
        cur[k] = v
    return values

TOKEN_RE = re.compile(r"\{\{-?\s*(.*?)\s*-?\}\}", re.S)

class TemplateError(Exception):
    pass

def tokenize(src):
    """Yield ('text', str) and ('action', str, ltrim, rtrim) tokens."""
    pos = 0
    for m in TOKEN_RE.finditer(src):
        if m.start() > pos:
            yield ("text", src[pos:m.start()], False, False)
        raw = src[m.start():m.end()]
        yield ("action", m.group(1), raw.startswith("{{-"), raw.endswith("-}}"))
        pos = m.end()
    if pos < len(src):
        yield ("text", src[pos:], False, False)

def parse(tokens):
    """Build nested block AST. Node: ('text', s) | ('action', s) |
    ('if', cond, body, elsebody) | ('range', expr, body) | ('define', name, body)"""
    def block(it, terminators):
        nodes = []
        for kind, val, lt, rt in it:
            if kind == "text":
                nodes.append(("text", val, lt, rt))
                continue
            word = val.split(None, 1)[0] if val.strip() else ""
            if word in terminators:
                return nodes, word, val, (lt, rt)
            if word == "if":
                body, term, tval, _ = block(it, {"end", "else"})
                elsebody = []
                if term == "else":
                    elsebody, term2, _, _ = block(it, {"end"})
                nodes.append(("if", val[2:].strip(), body, elsebody, lt, rt))
            elif word == "with":
                body, term, tval, _ = block(it, {"end", "else"})
                elsebody = []
                if term == "else":
                    elsebody, _, _, _ = block(it, {"end"})
                nodes.append(("with", val[4:].strip(), body, elsebody, lt, rt))
            elif word == "range":
                body, _, _, _ = block(it, {"end"})
                nodes.append(("range", val[5:].strip(), body, lt, rt))
            elif word == "define":
                name = re.findall(r'"([^"]+)"', val)[0]
                body, _, _, _ = block(it, {"end"})
                nodes.append(("define", name, body, lt, rt))
            elif word.startswith("/*") or val.strip().startswith("/*"):
                nodes.append(("text", "", lt, rt))
            else:
                nodes.append(("action", val, lt, rt))
        return nodes, None, None, None
    nodes, _, _, _ = block(iter(tokens), set())
    return nodes

def go_yaml(v, indent_level=0):
    if isinstance(v, (dict, list)):
        out = yaml.safe_dump(v, default_flow_style=False, sort_keys=False).rstrip("\n")
        return out
    return str(v)

class Renderer:
    def __init__(self, values, namespace="media"):
        self.defines = {}
        self.root = {
            "Values": values,
            "Release": {"Namespace": namespace, "Service": "Helm"},
            "Chart": self._chart(),
        }

    def _chart(self):
        with open(os.path.join(CHART_DIR, "Chart.yaml")) as f:
            c = yaml.safe_load(f)
        return {"Name": c["name"], "Version": c["version"]}

    def files_get(self, path):
        with open(os.path.join(CHART_DIR, path)) as f:
            return f.read()

    # ── expression evaluation ─────────────────────────────────────────────
    def split_args(self, s):
        args, depth, cur, inq = [], 0, "", False
        for ch in s:
            if ch == '"' and depth >= 0:
                inq = not inq; cur += ch
            elif inq:
                cur += ch
            elif ch == "(":
                depth += 1; cur += ch
            elif ch == ")":
                depth -= 1; cur += ch
            elif ch.isspace() and depth == 0:
                if cur: args.append(cur); cur = ""
            else:
                cur += ch
        if cur: args.append(cur)
        return args

    def eval_primary(self, expr, ctx, dot):
        expr = expr.strip()
        m = re.match(r'^\.Files\.Get\s+"([^"]+)"$', expr)
        if m:
            return self.files_get(m.group(1))
        if expr.startswith("(") and expr.endswith(")"):
            return self.eval_expr(expr[1:-1], ctx, dot)
        if expr.startswith('"'):
            return expr[1:-1].encode().decode("unicode_escape")
        if re.fullmatch(r"-?\d+", expr):
            return int(expr)
        if expr == ".":
            return dot
        if expr == "$":
            return self.root
        if expr.startswith("$."):
            v = self.root
            for part in expr[2:].split("."):
                v = v[part]
            return v
        if expr.startswith("$"):
            name = expr.split(".")[0]
            if name not in ctx:
                raise TemplateError(f"undefined variable {name}")
            v = ctx[name]
            for part in expr.split(".")[1:]:
                v = v[part]
            return v
        if expr.startswith("."):
            path = expr[1:].split(".")
            v = dot if isinstance(dot, dict) and path[0] in dot and path[0] not in self.root else None
            # root fields first (.Values, .Release, .Chart, .Files)
            if path[0] in ("Values", "Release", "Chart"):
                v = self.root[path[0]]
                path = path[1:]
            elif path[0] == "Files":
                return ("FILES", path[1:])
            else:
                v = dot
            for part in path:
                if v is None:
                    raise TemplateError(f"nil deref at {expr}")
                v = v.get(part) if isinstance(v, dict) else getattr(v, part)
            return v
        # function call
        parts = self.split_args(expr)
        fn, args = parts[0], parts[1:]
        return self.call(fn, [self.eval_primary(a, ctx, dot) for a in args], ctx, dot, raw_args=args)

    def call(self, fn, vals, ctx, dot, raw_args=None):
        if fn == "include":
            name, arg = vals[0], vals[1] if len(vals) > 1 else dot
            return self.render_nodes(self.defines[name], ctx={}, dot=arg).strip("\n")
        if fn == "and":
            out = True
            for v in vals:
                if v in (None, "", 0, [], {}) or v is False:
                    return v
                out = v
            return out
        if fn == "or":
            for v in vals:
                if not (v in (None, "", 0, [], {}) or v is False):
                    return v
            return vals[-1] if vals else False
        if fn == "printf":
            # Go verbs -> Python: %v (default) and %d/%s are all string-safe here
            fmt = vals[0].replace("%v", "%s")
            return fmt % tuple(vals[1:]) if len(vals) > 1 else fmt
        if fn == "concat":
            out = []
            for v in vals:
                out.extend(v if isinstance(v, list) else [v])
            return out
        if fn == "join":
            sep, lst = vals[0], vals[1]
            return sep.join(str(x) for x in lst)
        if fn == "append":
            return list(vals[0]) + [vals[1]]
        if fn == "index":
            v = vals[0]
            for k in vals[1:]:
                v = v[k]
            return v
        if fn == "eq":
            return vals[0] == vals[1]
        if fn == "ne":
            return vals[0] != vals[1]
        if fn == "not":
            return not vals[0]
        if fn == "empty":
            return not vals[0]
        if fn == "default":
            return vals[1] if vals[1] not in (None, "", 0, [], {}) else vals[0]
        if fn == "until":
            return list(range(int(vals[0])))
        if fn == "add":
            return sum(int(v) for v in vals)
        if fn == "div":
            return int(vals[0]) // int(vals[1])
        if fn == "int":
            return int(vals[0])
        if fn == "dict":
            return {vals[i]: vals[i + 1] for i in range(0, len(vals), 2)}
        if fn == "list":
            return list(vals)
        if fn == "required":
            msg, v = vals[0], vals[1]
            if v in (None, ""):
                raise TemplateError(f"required: {msg}")
            return v
        if fn == "quote":
            return json.dumps(str(vals[0]))
        if fn == "toYaml":
            return go_yaml(vals[0])
        if fn in ("nindent", "indent"):
            n, s = int(vals[0]), str(vals[1])
            pad = " " * n
            out = "\n".join(pad + l if l else l for l in s.split("\n"))
            return ("\n" + out) if fn == "nindent" else out
        raise TemplateError(f"unsupported function {fn}")

    def eval_expr(self, expr, ctx, dot):
        # pipeline
        segs, depth, cur, inq, out = [], 0, "", False, None
        for ch in expr:
            if ch == '"':
                inq = not inq; cur += ch
            elif inq:
                cur += ch
            elif ch == "(":
                depth += 1; cur += ch
            elif ch == ")":
                depth -= 1; cur += ch
            elif ch == "|" and depth == 0:
                segs.append(cur); cur = ""
            else:
                cur += ch
        segs.append(cur)
        val = self.eval_primary(segs[0], ctx, dot)
        if isinstance(val, tuple) and val and val[0] == "FILES":
            # .Files.Get "path" appears as primary with args in next segs? handled below
            pass
        for seg in segs[1:]:
            parts = self.split_args(seg.strip())
            fn, extra = parts[0], [self.eval_primary(a, ctx, dot) for a in parts[1:]]
            val = self.call(fn, extra + [val], ctx, dot)
        return val

    # ── node rendering ────────────────────────────────────────────────────
    def render_nodes(self, nodes, ctx, dot):
        out = []
        def emit(s):
            out.append(s)
        def trim_left():
            # remove trailing whitespace incl. newline from output
            if out:
                out[-1] = re.sub(r"[ \t]*\n?[ \t]*$", "", out[-1]) if False else out[-1].rstrip(" \t")
                if out[-1].endswith("\n"):
                    out[-1] = out[-1][:-1]
                out[-1] = out[-1].rstrip(" \t")
        pending_rtrim = [False]
        for node in nodes:
            kind = node[0]
            lt = node[-2] if len(node) >= 4 else False
            rt = node[-1] if len(node) >= 4 else False
            if kind == "text":
                s = node[1]
                if pending_rtrim[0]:
                    s = re.sub(r"^[ \t]*\n?", "", s, count=1)
                    pending_rtrim[0] = False
                emit(s)
                continue
            if lt:
                trim_left()
            if kind == "action":
                expr = node[1].strip()
                m = re.match(r"^(\$[A-Za-z0-9_]+)\s*:?=\s*(.+)$", expr, re.S)
                if m:
                    ctx[m.group(1)] = self.eval_expr(m.group(2), ctx, dot)
                elif expr.startswith("/*"):
                    pass
                else:
                    v = self.eval_expr(expr, ctx, dot)
                    if isinstance(v, tuple) and v and v[0] == "FILES":
                        raise TemplateError("Files must be piped")
                    emit("" if v is None else str(v))
            elif kind == "if":
                cond, body, elsebody = node[1], node[2], node[3]
                v = self.eval_expr(cond, ctx, dot)
                emit(self.render_nodes(body if v else elsebody, dict(ctx), dot))
            elif kind == "with":
                expr, body, elsebody = node[1], node[2], node[3]
                v = self.eval_expr(expr, ctx, dot)
                if v not in (None, "", 0, [], {}) and v is not False:
                    emit(self.render_nodes(body, dict(ctx), v))
                else:
                    emit(self.render_nodes(elsebody, dict(ctx), dot))
            elif kind == "range":
                spec, body = node[1], node[2]
                mm = re.match(r"^(\$[A-Za-z0-9_]+)\s*,\s*(\$[A-Za-z0-9_]+)\s*:?=\s*(.+)$", spec, re.S)
                if mm:
                    kvar, vvar, coll = mm.group(1), mm.group(2), self.eval_expr(mm.group(3), ctx, dot)
                    pieces = []
                    items = coll.items() if isinstance(coll, dict) else enumerate(coll or [])
                    for k, v in items:
                        c2 = dict(ctx); c2[kvar] = k; c2[vvar] = v
                        pieces.append(self.render_nodes(body, c2, dot))
                    emit("".join(pieces))
                    if rt:
                        pending_rtrim[0] = True
                    continue
                m = re.match(r"^(\$[A-Za-z0-9_]+)\s*:?=\s*(.+)$", spec, re.S)
                pieces = []
                if m:
                    var, coll = m.group(1), self.eval_expr(m.group(2), ctx, dot)
                    for item in coll:
                        c2 = dict(ctx); c2[var] = item
                        pieces.append(self.render_nodes(body, c2, dot))
                else:
                    coll = self.eval_expr(spec, ctx, dot)
                    for item in coll or []:
                        pieces.append(self.render_nodes(body, dict(ctx), item))
                emit("".join(pieces))
            elif kind == "define":
                self.defines[node[1]] = node[2]
            if rt:
                pending_rtrim[0] = True
        return "".join(out)

    def render_file(self, path, dot=None):
        src = open(path).read()
        nodes = parse(tokenize(src))
        return self.render_nodes(nodes, ctx={}, dot=dot if dot is not None else self.root)

def main():
    sets = []
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--set":
            sets.append(args[i + 1]); i += 2
        else:
            i += 1
    values = load_values(sets)
    r = Renderer(values)
    # special-case: .Files.Get pipeline in configmaps
    r.eval_primary_orig = r.eval_primary
    tpl_dir = os.path.join(CHART_DIR, "templates")
    # load helpers first
    r.render_file(os.path.join(tpl_dir, "_helpers.tpl"))
    outputs = []
    for fn in sorted(os.listdir(tpl_dir)):
        if fn.startswith("_") or fn == "NOTES.txt" or not (fn.endswith(".yaml") or fn.endswith(".yml")):
            continue
        rendered = r.render_file(os.path.join(tpl_dir, fn))
        outputs.append(f"---\n# Source: templates/{fn}\n{rendered.strip()}\n")
    print("\n".join(outputs))

if __name__ == "__main__":
    main()
