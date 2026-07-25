//! A pure-Zig, dependency-free TOML **subset** parser/stringifier over
//! z-value's `JSValue` -- the same target type z-json/z-yaml build, so
//! TOML documents interoperate freely with JSON/YAML ones once parsed.
//!
//! This is NOT a TOML 1.0.0-conformant implementation. It covers the
//! subset that shows up in the large majority of real-world config files
//! (Cargo.toml/pyproject.toml-shaped documents):
//!
//! - Key/value pairs (`key = value`), one per line; bare keys
//!   (`[A-Za-z0-9_-]+`), quoted keys (`"..."`/`'...'`), and dotted keys
//!   (`a.b.c = 1`, creating/reusing nested tables).
//! - Standard tables (`[table]`, `[table.dotted]`) and arrays of tables
//!   (`[[table]]`), including nesting a table under the last entry of an
//!   existing array of tables.
//! - Strings: basic `"..."` (JSON-style escapes: \b \t \n \f \r \" \\
//!   \uXXXX \UXXXXXXXX) and literal `'...'` (verbatim, no escapes) --
//!   single-line only.
//! - Integers (decimal with `_` digit separators, and `0x`/`0o`/`0b`
//!   hex/octal/binary) and floats (with `_`, exponents, `inf`/`-inf`/`nan`).
//! - Booleans (`true`/`false`).
//! - Arrays (`[1, 2, 3]`), which -- unlike this ecosystem's YAML flow
//!   collections -- MAY span multiple lines with comments, matching real
//!   TOML.
//! - Inline tables (`{ a = 1, b = 2 }`), single logical line only (a real
//!   TOML restriction, enforced here too).
//! - `#` comments and blank lines.
//!
//! Explicitly NOT supported (documented, not silently wrong):
//! - Multi-line strings (`"""..."""`, `'''...'''`) -- a parse error.
//! - Native date-time/date/time values are recognized syntactically but
//!   parsed as plain JS strings, not a distinct type (there's no
//!   TOML-flavored temporal type on `JSValue` to map them onto -- the same
//!   asymmetry z-yaml already has for dates). `stringify` mirrors this: a
//!   `.date` JSValue is written as a quoted string, not a native TOML
//!   datetime literal.
//! - Strict TOML validation (duplicate table/key redefinition rules,
//!   underscore-placement strictness, leading-zero rejection) -- this
//!   parser is lenient where real TOML would reject; a genuinely malformed
//!   document is still a parse error, just not necessarily for the exact
//!   reason the spec would cite.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

pub const TomlError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    /// A table/key path collides with a non-table value already at that
    /// path (e.g. `[a]` after `a = 1`, or `[[a]]` where `a` isn't already
    /// an array of tables).
    DuplicateKey,
    /// A multi-line string (`"""`/`'''`) was encountered -- deferred (see
    /// the module doc comment).
    UnsupportedFeature,
    /// stringify() only: the top-level value isn't an object (TOML
    /// documents are always tables), or a value has no TOML
    /// representation (map/set/regex/error/promise/symbol/function,
    /// undefined/null as an array element).
    Unserializable,
    /// stringify() only: a cycle in the value graph.
    CircularStructure,
    OutOfMemory,
};

// ============================================================================
// Shared helpers
// ============================================================================

fn isBareKeyChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// A date/date-time/time-only literal, recognized syntactically only --
/// see the module doc comment's "NOT supported" section for why this
/// becomes a plain string rather than a distinct JSValue type.
fn looksLikeDateTime(s: []const u8) bool {
    if (s.len >= 10 and isDigits(s[0..4]) and s[4] == '-' and isDigits(s[5..7]) and s[7] == '-' and isDigits(s[8..10])) return true;
    if (s.len >= 8 and isDigits(s[0..2]) and s[2] == ':' and isDigits(s[3..5]) and s[5] == ':' and isDigits(s[6..8])) return true;
    return false;
}

/// `[+-]?digit(_?digit)*(\.digit(_?digit)*)?([eE][+-]?digit(_?digit)*)?`,
/// requiring the entire string to match and at least one digit.
fn looksLikeDecimalNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var saw_digit = false;
    var saw_dot = false;
    var prev_digit = false;
    while (i < s.len) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            saw_digit = true;
            prev_digit = true;
            i += 1;
        } else if (c == '_' and prev_digit and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '9') {
            prev_digit = false;
            i += 1;
        } else if (c == '.' and !saw_dot and prev_digit) {
            saw_dot = true;
            prev_digit = false;
            i += 1;
        } else if ((c == 'e' or c == 'E') and saw_digit) {
            i += 1;
            if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
            const exp_start = i;
            while (i < s.len and (s[i] == '_' or (s[i] >= '0' and s[i] <= '9'))) i += 1;
            if (i == exp_start) return false;
            return i == s.len;
        } else {
            return false;
        }
    }
    return saw_digit and i == s.len;
}

fn stripUnderscores(allocator: Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        if (c != '_') try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

/// Classifies an unquoted value token: bool, `inf`/`nan`, a recognized
/// date/time shape (-> string, see module doc comment), a `0x`/`0o`/`0b`
/// integer, or a decimal int/float.
fn classifyUnquoted(allocator: Allocator, raw: []const u8) TomlError!JSValue {
    if (std.mem.eql(u8, raw, "true")) return JSValue.fromBool(true);
    if (std.mem.eql(u8, raw, "false")) return JSValue.fromBool(false);
    if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf")) return JSValue.fromNumber(std.math.inf(f64));
    if (std.mem.eql(u8, raw, "-inf")) return JSValue.fromNumber(-std.math.inf(f64));
    if (std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan") or std.mem.eql(u8, raw, "-nan")) return JSValue.fromNumber(std.math.nan(f64));
    if (looksLikeDateTime(raw)) return JSValue.newString(allocator, raw);
    if (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'o' or raw[1] == 'b')) {
        const radix: u8 = switch (raw[1]) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => unreachable,
        };
        const stripped = try stripUnderscores(allocator, raw[2..]);
        defer allocator.free(stripped);
        const n = std.fmt.parseInt(i64, stripped, radix) catch return TomlError.InvalidNumber;
        return JSValue.fromNumber(@floatFromInt(n));
    }
    if (looksLikeDecimalNumber(raw)) {
        const stripped = try stripUnderscores(allocator, raw);
        defer allocator.free(stripped);
        return JSValue.fromNumber(znumber.ParsingMethods.parseFloat(stripped));
    }
    return TomlError.UnexpectedToken;
}

// ============================================================================
// Parser
// ============================================================================

const Parser = struct {
    allocator: Allocator,
    s: []const u8,
    pos: usize,

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.s.len;
    }
    fn peek(self: *const Parser) u8 {
        return self.s[self.pos];
    }
    fn peekAt(self: *const Parser, offset: usize) ?u8 {
        return if (self.pos + offset < self.s.len) self.s[self.pos + offset] else null;
    }

    fn isInlineSpace(c: u8) bool {
        return c == ' ' or c == '\t';
    }
    fn skipInlineWhitespace(self: *Parser) void {
        while (!self.atEnd() and isInlineSpace(self.peek())) self.pos += 1;
    }
    fn skipWhitespaceAndComments(self: *Parser) void {
        while (!self.atEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (!self.atEnd() and self.peek() != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }
    /// After a value or table header: optional trailing whitespace/comment,
    /// then a newline or end-of-input. Anything else is trailing garbage.
    fn skipToLineEnd(self: *Parser) TomlError!void {
        self.skipInlineWhitespace();
        if (self.atEnd()) return;
        if (self.peek() == '#') {
            while (!self.atEnd() and self.peek() != '\n') self.pos += 1;
        }
        if (self.atEnd()) return;
        if (self.peek() == '\r') self.pos += 1;
        if (!self.atEnd() and self.peek() == '\n') {
            self.pos += 1;
            return;
        }
        return TomlError.UnexpectedToken;
    }

    fn expectChar(self: *Parser, c: u8) TomlError!void {
        if (self.atEnd() or self.peek() != c) return TomlError.UnexpectedToken;
        self.pos += 1;
    }
    fn expectSlice(self: *Parser, s: []const u8) TomlError!void {
        if (self.pos + s.len > self.s.len or !std.mem.eql(u8, self.s[self.pos .. self.pos + s.len], s)) return TomlError.UnexpectedToken;
        self.pos += s.len;
    }

    /// Decodes a basic (double-quoted) string body, single-line only --
    /// `"""` at the opening quote is UnsupportedFeature (multi-line,
    /// deferred). Returns owned, decoded bytes; advances past the closing
    /// quote.
    fn parseBasicString(self: *Parser) TomlError![]u8 {
        std.debug.assert(self.peek() == '"');
        if (self.peekAt(1) == '"' and self.peekAt(2) == '"') return TomlError.UnsupportedFeature;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        self.pos += 1;
        while (true) {
            if (self.atEnd()) return TomlError.UnterminatedString;
            const c = self.s[self.pos];
            if (c == '"') {
                self.pos += 1;
                break;
            }
            if (c == '\n') return TomlError.UnterminatedString;
            if (c != '\\') {
                try buf.append(self.allocator, c);
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.atEnd()) return TomlError.UnterminatedString;
            switch (self.s[self.pos]) {
                '"' => {
                    try buf.append(self.allocator, '"');
                    self.pos += 1;
                },
                '\\' => {
                    try buf.append(self.allocator, '\\');
                    self.pos += 1;
                },
                'b' => {
                    try buf.append(self.allocator, 0x08);
                    self.pos += 1;
                },
                'f' => {
                    try buf.append(self.allocator, 0x0C);
                    self.pos += 1;
                },
                'n' => {
                    try buf.append(self.allocator, '\n');
                    self.pos += 1;
                },
                'r' => {
                    try buf.append(self.allocator, '\r');
                    self.pos += 1;
                },
                't' => {
                    try buf.append(self.allocator, '\t');
                    self.pos += 1;
                },
                'u' => {
                    self.pos += 1;
                    if (self.pos + 4 > self.s.len) return TomlError.UnterminatedString;
                    const cp = std.fmt.parseInt(u21, self.s[self.pos .. self.pos + 4], 16) catch return TomlError.InvalidEscape;
                    self.pos += 4;
                    var enc: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &enc) catch return TomlError.InvalidEscape;
                    try buf.appendSlice(self.allocator, enc[0..len]);
                },
                'U' => {
                    self.pos += 1;
                    if (self.pos + 8 > self.s.len) return TomlError.UnterminatedString;
                    const cp = std.fmt.parseInt(u21, self.s[self.pos .. self.pos + 8], 16) catch return TomlError.InvalidEscape;
                    self.pos += 8;
                    var enc: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &enc) catch return TomlError.InvalidEscape;
                    try buf.appendSlice(self.allocator, enc[0..len]);
                },
                else => return TomlError.InvalidEscape,
            }
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Decodes a literal (single-quoted) string body, verbatim, single-line
    /// only -- `'''` at the opening quote is UnsupportedFeature.
    fn parseLiteralString(self: *Parser) TomlError![]u8 {
        std.debug.assert(self.peek() == '\'');
        if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') return TomlError.UnsupportedFeature;
        self.pos += 1;
        const start = self.pos;
        while (true) {
            if (self.atEnd()) return TomlError.UnterminatedString;
            if (self.s[self.pos] == '\'') break;
            if (self.s[self.pos] == '\n') return TomlError.UnterminatedString;
            self.pos += 1;
        }
        const raw = self.s[start..self.pos];
        self.pos += 1;
        return self.allocator.dupe(u8, raw);
    }

    fn parseKeySegment(self: *Parser) TomlError![]const u8 {
        self.skipInlineWhitespace();
        if (self.atEnd()) return TomlError.UnexpectedEnd;
        if (self.peek() == '"') return self.parseBasicString();
        if (self.peek() == '\'') return self.parseLiteralString();
        const start = self.pos;
        while (!self.atEnd() and isBareKeyChar(self.peek())) self.pos += 1;
        if (self.pos == start) return TomlError.UnexpectedToken;
        return self.allocator.dupe(u8, self.s[start..self.pos]);
    }

    fn parseDottedKeyPath(self: *Parser) TomlError![]const []const u8 {
        var segs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (segs.items) |seg| self.allocator.free(seg);
            segs.deinit(self.allocator);
        }
        while (true) {
            const seg = try self.parseKeySegment();
            try segs.append(self.allocator, seg);
            self.skipInlineWhitespace();
            if (!self.atEnd() and self.peek() == '.') {
                self.pos += 1;
                continue;
            }
            break;
        }
        return segs.toOwnedSlice(self.allocator);
    }

    fn isValueDelimiter(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', ',', ']', '}', '#' => true,
            else => false,
        };
    }

    fn parseUnquotedValue(self: *Parser) TomlError!JSValue {
        const start = self.pos;
        while (!self.atEnd() and !isValueDelimiter(self.peek())) self.pos += 1;
        if (self.pos == start) return TomlError.UnexpectedToken;
        return classifyUnquoted(self.allocator, self.s[start..self.pos]);
    }

    fn parseArrayValue(self: *Parser) TomlError!JSValue {
        std.debug.assert(self.peek() == '[');
        self.pos += 1;
        var arr = try JSValue.newArray(self.allocator);
        errdefer arr.deinit();
        self.skipWhitespaceAndComments();
        if (!self.atEnd() and self.peek() == ']') {
            self.pos += 1;
            return arr;
        }
        while (true) {
            self.skipWhitespaceAndComments();
            if (self.atEnd()) return TomlError.UnexpectedEnd;
            const val = try self.parseValue();
            errdefer val.deinit();
            _ = try arr.array.value.push(val);
            self.skipWhitespaceAndComments();
            if (self.atEnd()) return TomlError.UnexpectedEnd;
            if (self.peek() == ',') {
                self.pos += 1;
                self.skipWhitespaceAndComments();
                if (!self.atEnd() and self.peek() == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (self.peek() == ']') {
                self.pos += 1;
                break;
            }
            return TomlError.UnexpectedToken;
        }
        return arr;
    }

    fn parseInlineTableValue(self: *Parser) TomlError!JSValue {
        std.debug.assert(self.peek() == '{');
        self.pos += 1;
        var obj = try JSValue.newObject(self.allocator);
        errdefer obj.deinit();
        self.skipInlineWhitespace();
        if (!self.atEnd() and self.peek() == '}') {
            self.pos += 1;
            return obj;
        }
        while (true) {
            self.skipInlineWhitespace();
            const segs = try self.parseDottedKeyPath();
            defer freeSegs(self.allocator, segs);
            self.skipInlineWhitespace();
            try self.expectChar('=');
            self.skipInlineWhitespace();
            const val = try self.parseValue();
            errdefer val.deinit();
            try setAtPath(self.allocator, obj, segs, val);
            self.skipInlineWhitespace();
            if (self.atEnd()) return TomlError.UnexpectedEnd;
            if (self.peek() == ',') {
                self.pos += 1;
                continue;
            }
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            return TomlError.UnexpectedToken;
        }
        return obj;
    }

    fn parseValue(self: *Parser) TomlError!JSValue {
        if (self.atEnd()) return TomlError.UnexpectedEnd;
        switch (self.peek()) {
            '"' => {
                const body = try self.parseBasicString();
                defer self.allocator.free(body);
                return JSValue.newString(self.allocator, body);
            },
            '\'' => {
                const body = try self.parseLiteralString();
                defer self.allocator.free(body);
                return JSValue.newString(self.allocator, body);
            },
            '[' => return self.parseArrayValue(),
            '{' => return self.parseInlineTableValue(),
            else => return self.parseUnquotedValue(),
        }
    }
};

fn freeSegs(allocator: Allocator, segs: []const []const u8) void {
    for (segs) |seg| allocator.free(seg);
    allocator.free(segs);
}

/// Sets `value` at `segs` under `obj` (the LAST segment is the key that
/// gets `value`; earlier segments navigate/create intermediate tables).
fn setAtPath(allocator: Allocator, obj: JSValue, segs: []const []const u8, value: JSValue) TomlError!void {
    std.debug.assert(segs.len > 0);
    const parent = if (segs.len == 1) obj else try navigateCreatePath(allocator, obj, segs[0 .. segs.len - 1]);
    parent.object.value.set(segs[segs.len - 1], value) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // a table built by this parser is never frozen
    };
}

/// Walks `segments` under `base`, creating a fresh object for any segment
/// that doesn't exist yet, or reusing one that does; a segment that's an
/// existing array of tables steps into that array's LAST element (the
/// `[[a]]` then `[a.b]` pattern). Returns the innermost table.
fn navigateCreatePath(allocator: Allocator, base: JSValue, segments: []const []const u8) TomlError!JSValue {
    var cur = base;
    for (segments) |seg| {
        if (cur.object.value.get(seg)) |existing| {
            if (existing == .object) {
                cur = existing;
            } else if (existing == .array) {
                const items = existing.array.value.toSlice();
                if (items.len == 0 or items[items.len - 1] != .object) return TomlError.DuplicateKey;
                cur = items[items.len - 1];
            } else {
                return TomlError.DuplicateKey;
            }
        } else {
            const obj = try JSValue.newObject(allocator);
            cur.object.value.set(seg, obj) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            cur = obj;
        }
    }
    return cur;
}

/// `[[segments]]`: navigates all but the last segment like
/// `navigateCreatePath`, then get-or-creates an array at the last segment
/// and appends a fresh table to it, returning that new table.
fn navigateArrayOfTables(allocator: Allocator, base: JSValue, segments: []const []const u8) TomlError!JSValue {
    std.debug.assert(segments.len > 0);
    const parent = try navigateCreatePath(allocator, base, segments[0 .. segments.len - 1]);
    const last = segments[segments.len - 1];
    var arr: JSValue = undefined;
    if (parent.object.value.get(last)) |existing| {
        if (existing != .array) return TomlError.DuplicateKey;
        arr = existing;
    } else {
        arr = try JSValue.newArray(allocator);
        parent.object.value.set(last, arr) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }
    const table = try JSValue.newObject(allocator);
    _ = try arr.array.value.push(table);
    return table;
}

/// Parses a TOML document (the SUBSET described in this module's doc
/// comment) into a `JSValue` object tree, freeable with one top-level
/// `.deinit()` like any other `JSValue` tree.
pub fn parse(allocator: Allocator, text: []const u8) TomlError!JSValue {
    var root = try JSValue.newObject(allocator);
    errdefer root.deinit();
    var p = Parser{ .allocator = allocator, .s = text, .pos = 0 };
    var current = root;
    while (true) {
        p.skipWhitespaceAndComments();
        if (p.atEnd()) break;
        if (p.peek() == '[') {
            if (p.peekAt(1) == '[') {
                p.pos += 2;
                const segs = try p.parseDottedKeyPath();
                defer freeSegs(allocator, segs);
                try p.expectSlice("]]");
                current = try navigateArrayOfTables(allocator, root, segs);
                try p.skipToLineEnd();
                continue;
            }
            p.pos += 1;
            const segs = try p.parseDottedKeyPath();
            defer freeSegs(allocator, segs);
            try p.expectChar(']');
            current = try navigateCreatePath(allocator, root, segs);
            try p.skipToLineEnd();
            continue;
        }
        const segs = try p.parseDottedKeyPath();
        defer freeSegs(allocator, segs);
        p.skipInlineWhitespace();
        try p.expectChar('=');
        p.skipInlineWhitespace();
        const value = try p.parseValue();
        errdefer value.deinit();
        try setAtPath(allocator, current, segs, value);
        try p.skipToLineEnd();
    }
    return root;
}

// ============================================================================
// Stringify: JSValue -> TOML
// ============================================================================

fn isUnserializable(v: JSValue) bool {
    return switch (v) {
        .@"undefined", .@"null", .symbol, .function, .map, .set, .regex, .@"error", .promise => true,
        else => false,
    };
}

fn writeString(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn isBareKeyOnly(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isBareKeyChar(c)) return false;
    }
    return true;
}

fn writeKey(allocator: Allocator, buf: *std.ArrayList(u8), key: []const u8) !void {
    if (isBareKeyOnly(key)) {
        try buf.appendSlice(allocator, key);
    } else {
        try writeString(allocator, buf, key);
    }
}

/// An array counts as an "array of tables" (renderable as `[[path]]`
/// sections) when non-empty and every element is a plain object.
fn isArrayOfTables(v: JSValue) bool {
    const items = v.array.value.toSlice();
    if (items.len == 0) return false;
    for (items) |item| {
        if (item != .object) return false;
    }
    return true;
}

const SeenStack = std.ArrayList(usize);

fn seenContains(seen: *const SeenStack, ptr: usize) bool {
    for (seen.items) |p| {
        if (p == ptr) return true;
    }
    return false;
}

/// Renders any value INLINE (used for array elements and inline-table
/// values -- objects here always become `{...}`, never a `[table]`
/// section; only `writeTable`'s top-level key dispatch promotes an
/// object/array-of-tables to its own section).
fn writeValue(allocator: Allocator, buf: *std.ArrayList(u8), seen: *SeenStack, value: JSValue) TomlError!void {
    if (isUnserializable(value)) return TomlError.Unserializable;
    switch (value) {
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| {
            if (std.math.isNan(n)) {
                try buf.appendSlice(allocator, "nan");
            } else if (n == std.math.inf(f64)) {
                try buf.appendSlice(allocator, "inf");
            } else if (n == -std.math.inf(f64)) {
                try buf.appendSlice(allocator, "-inf");
            } else {
                const s = znumber.FormattingMethods.toString(n, allocator, null) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
            }
        },
        .string => |box| try writeString(allocator, buf, box.value.data),
        .date => |box| {
            const iso = box.value.toISOString(allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return buf.appendSlice(allocator, "\"\""),
            };
            defer allocator.free(iso);
            try writeString(allocator, buf, iso);
        },
        .array => |box| {
            const addr = @intFromPtr(box);
            if (seenContains(seen, addr)) return TomlError.CircularStructure;
            try seen.append(allocator, addr);
            defer _ = seen.pop();
            try buf.append(allocator, '[');
            const items = box.value.toSlice();
            for (items, 0..) |item, i| {
                if (i != 0) try buf.appendSlice(allocator, ", ");
                try writeValue(allocator, buf, seen, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |box| {
            const addr = @intFromPtr(box);
            if (seenContains(seen, addr)) return TomlError.CircularStructure;
            try seen.append(allocator, addr);
            defer _ = seen.pop();
            try buf.append(allocator, '{');
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            var wrote_one = false;
            for (keys) |key| {
                if (key.len > 0 and key[0] == 0) continue; // internal symbol-key encoding
                const v = box.value.get(key).?;
                if (isUnserializable(v)) continue; // omitted, matching JSON.stringify's object-property convention
                if (wrote_one) try buf.appendSlice(allocator, ", ");
                wrote_one = true;
                try writeKey(allocator, buf, key);
                try buf.appendSlice(allocator, " = ");
                try writeValue(allocator, buf, seen, v);
            }
            try buf.append(allocator, '}');
        },
        else => unreachable, // isUnserializable() already filtered everything else out
    }
}

fn writeIndent(allocator: Allocator, buf: *std.ArrayList(u8), depth: usize) !void {
    try buf.appendNTimes(allocator, ' ', depth * 2);
}

fn writeDottedPath(allocator: Allocator, buf: *std.ArrayList(u8), path: []const []const u8) !void {
    for (path, 0..) |seg, i| {
        if (i != 0) try buf.append(allocator, '.');
        try writeKey(allocator, buf, seg);
    }
}

/// Writes `obj`'s own scalar/array/inline-table-shaped properties as
/// `key = value` lines, THEN recurses into each object-valued or
/// array-of-tables-valued property as its own `[path]`/`[[path]]`
/// section -- matching how real TOML requires a table's direct keys to
/// precede any subtable.
fn writeTable(allocator: Allocator, buf: *std.ArrayList(u8), seen: *SeenStack, obj: JSValue, path: []const []const u8, depth: usize) TomlError!void {
    const box = obj.object;
    const addr = @intFromPtr(box);
    if (seenContains(seen, addr)) return TomlError.CircularStructure;
    try seen.append(allocator, addr);
    defer _ = seen.pop();

    const keys = try box.value.keys(allocator);
    defer allocator.free(keys);

    for (keys) |key| {
        if (key.len > 0 and key[0] == 0) continue;
        const v = box.value.get(key).?;
        if (v == .object) continue;
        if (v == .array and isArrayOfTables(v)) continue;
        if (isUnserializable(v)) continue;
        try writeIndent(allocator, buf, depth);
        try writeKey(allocator, buf, key);
        try buf.appendSlice(allocator, " = ");
        try writeValue(allocator, buf, seen, v);
        try buf.append(allocator, '\n');
    }

    for (keys) |key| {
        if (key.len > 0 and key[0] == 0) continue;
        const v = box.value.get(key).?;
        if (v == .object) {
            var child_path: std.ArrayList([]const u8) = .empty;
            defer child_path.deinit(allocator);
            try child_path.appendSlice(allocator, path);
            try child_path.append(allocator, key);
            try buf.append(allocator, '\n');
            try buf.append(allocator, '[');
            try writeDottedPath(allocator, buf, child_path.items);
            try buf.appendSlice(allocator, "]\n");
            try writeTable(allocator, buf, seen, v, child_path.items, depth);
        } else if (v == .array and isArrayOfTables(v)) {
            var child_path: std.ArrayList([]const u8) = .empty;
            defer child_path.deinit(allocator);
            try child_path.appendSlice(allocator, path);
            try child_path.append(allocator, key);
            for (v.array.value.toSlice()) |elem| {
                try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, "[[");
                try writeDottedPath(allocator, buf, child_path.items);
                try buf.appendSlice(allocator, "]]\n");
                try writeTable(allocator, buf, seen, elem, child_path.items, depth);
            }
        }
    }
}

/// Serializes a `JSValue` object to TOML. The top-level value MUST be an
/// object (real TOML documents are always tables) -- anything else is
/// `TomlError.Unserializable`. The inverse of `parse` for everything in
/// this module's subset, modulo comments/formatting and the date/time
/// asymmetry documented at the top of this file.
pub fn stringify(allocator: Allocator, value: JSValue) TomlError![]u8 {
    if (value != .object) return TomlError.Unserializable;
    var seen: SeenStack = .empty;
    defer seen.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeTable(allocator, &buf, &seen, value, &.{}, 0);
    const out = try buf.toOwnedSlice(allocator);
    // writeTable prefixes every [table]/[[table]] section with a blank
    // line to separate it from what precedes it; if the root has no
    // direct scalar keys, that leaves a stray leading blank line.
    const trimmed = std.mem.trimStart(u8, out, "\n");
    if (trimmed.len == out.len) return out;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(out);
    return result;
}
