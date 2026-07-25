# Z-TOML

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A **pure-Zig, dependency-free TOML *subset*** parser/stringifier over [z-value](https://github.com/carlos-sweb/z-value)'s `JSValue`, in Zig 0.16, part of the [z-*](https://github.com/carlos-sweb) micro-library ecosystem. Same shape as [z-json](https://github.com/carlos-sweb/z-json) and [z-yaml](https://github.com/carlos-sweb/z-yaml) — a TOML document, once parsed, is a normal `JSValue` tree and interoperates freely with JSON/YAML ones.

## Why a subset

Full TOML 1.0.0 has real depth once you count multi-line basic/literal strings, four distinct native date/time types, and strict validation rules around table/key redefinition. This repo covers the subset that shows up in the large majority of real-world config files (Cargo.toml/pyproject.toml-shaped documents) — deliberately narrowed, and documented as such, rather than silently wrong on the parts it doesn't support.

## Scope

**Supported:**
- Key/value pairs (`key = value`); bare keys (`[A-Za-z0-9_-]+`), quoted keys (`"..."`/`'...'`), and dotted keys (`a.b.c = 1`, creating/reusing nested tables).
- Standard tables (`[table]`, `[table.dotted]`) and arrays of tables (`[[table]]`), including nesting a table under the last entry of an existing array of tables (`[[fruit]]` then `[fruit.physical]`).
- Strings: basic `"..."` (JSON-style escapes: `\n \t \" \\ \uXXXX \UXXXXXXXX`) and literal `'...'` (verbatim) — single-line only.
- Integers — decimal with `_` digit separators, and `0x`/`0o`/`0b` hex/octal/binary — and floats (with `_`, exponents, `inf`/`-inf`/`nan`).
- Booleans.
- Arrays (`[1, 2, 3]`), which **may span multiple lines** with comments and trailing commas, unlike this ecosystem's YAML flow collections (matching real TOML — YAML flow syntax is restricted to a single line by choice; TOML arrays are not).
- Inline tables (`{ a = 1, b = 2 }`), single logical line only (a real TOML restriction, enforced here too).
- `#` comments and blank lines.

**Explicitly NOT supported** (a parse error, never silently misinterpreted data, never a crash):
- Multi-line strings (`"""..."""`, `'''...'''`).
- Native date-time typing — a date/time-shaped literal (`1979-05-27T07:32:00Z`, `07:32:00`) is recognized syntactically and parsed as a **plain string**, not a distinct type (there's no TOML-flavored temporal type on `JSValue` to map it onto — the same asymmetry [z-yaml](https://github.com/carlos-sweb/z-yaml) already has for dates). `stringify` mirrors this: a `.date` `JSValue` is written as a quoted string, not a native TOML datetime literal.
- Strict TOML validation (duplicate table/key redefinition rules, underscore-placement strictness, leading-zero rejection) — lenient where real TOML would reject; a genuinely malformed document is still a parse error, just not necessarily for the spec's exact reason.

## Design

- **`parse(allocator, text) TomlError!JSValue`** — a single-pass cursor parser: top-level key/value lines and `[table]`/`[[table]]` headers update a "current insertion point" table; dotted keys/paths navigate or create nested `JSValue` objects as they go. The returned tree is a normal `JSValue` tree — free it with one top-level `.deinit()`, same as z-json's/z-yaml's `parse()`.
- **`stringify(allocator, value) TomlError![]u8`** — the top-level value must be an object (real TOML documents are always tables). Writes a table's own scalar/inline-shaped keys first, then recurses into nested objects as `[path]` sections and arrays-of-objects as `[[path]]` sections, matching TOML's requirement that a table's direct keys precede any subtable. Cycle-checked (`TomlError.CircularStructure`), same convention as z-json.
- **`TomlError`**: `UnexpectedToken`, `UnexpectedEnd`, `UnterminatedString`, `InvalidEscape`, `InvalidNumber`, `DuplicateKey`, `UnsupportedFeature` (multi-line strings), `Unserializable`/`CircularStructure` (`stringify` only), `OutOfMemory`.

## Usage

```zig
const ztoml = @import("ztoml");

var doc = try ztoml.parse(allocator,
    \\name = "app"
    \\
    \\[server]
    \\host = "localhost"
    \\port = 8080
    \\
    \\[[bin]]
    \\name = "cli"
);
defer doc.deinit();
// doc.object.value.get("server").?.object.value.get("port").?.number == 8080
// doc.object.value.get("bin").?.array.value.toSlice()[0].object.value.get("name")...

const out = try ztoml.stringify(allocator, doc);
defer allocator.free(out);
```
