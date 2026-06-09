# aftk

AFTK provides the `aftk` Lake executable for dependency analysis of Lean declarations.

```bash
lake exe aftk deps [options] <module> <declaration>
lake exe aftk rdeps [options] <module> <declaration>
```

By default, both commands print tab-separated rows:

```text
<module>\t<declaration>
```

Use `--jsonl` to print one JSON object per result:

```json
{"module":"Mathlib...","declaration":"..."}
```

Use `--module` / `--modules` to restrict output to exact modules or module prefixes:

```bash
lake exe aftk deps Mathlib.Data.Nat.Basic Nat.gcd --module 'Mathlib.Algebra.*'
lake exe aftk rdeps Mathlib.Data.Nat.Basic Nat.gcd --modules 'Mathlib.Algebra.*,Mathlib.Order.*'
```

Run `lake exe aftk --help` or `lake exe aftk <command> --help` for full help.

For large imports such as Mathlib, prefer using module filters with `rdeps`.
