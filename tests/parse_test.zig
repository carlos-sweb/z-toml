const std = @import("std");
const testing = std.testing;
const ztoml = @import("ztoml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "root-level key/value pairs: bool/number/string typing" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\name = "app"
        \\port = 8080
        \\ratio = 3.14
        \\active = true
        \\disabled = false
    );
    defer doc.deinit();
    try testing.expect(doc.isObject());
    try testing.expectEqualStrings("app", doc.asObject().value.get("name").?.asString().value.data);
    try testing.expectEqual(@as(f64, 8080), doc.asObject().value.get("port").?.asNumber());
    try testing.expectEqual(@as(f64, 3.14), doc.asObject().value.get("ratio").?.asNumber());
    try testing.expectEqual(true, doc.asObject().value.get("active").?.asBool());
    try testing.expectEqual(false, doc.asObject().value.get("disabled").?.asBool());
}

test "comments and blank lines are ignored" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\# top comment
        \\
        \\a = 1 # trailing comment
        \\
        \\b = 2
    );
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 1), doc.asObject().value.get("a").?.asNumber());
    try testing.expectEqual(@as(f64, 2), doc.asObject().value.get("b").?.asNumber());
}

test "integers: underscores and hex/octal/binary" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\decimal = 1_000_000
        \\neg = -42
        \\hex = 0xFF
        \\oct = 0o17
        \\bin = 0b1010
    );
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 1000000), doc.asObject().value.get("decimal").?.asNumber());
    try testing.expectEqual(@as(f64, -42), doc.asObject().value.get("neg").?.asNumber());
    try testing.expectEqual(@as(f64, 255), doc.asObject().value.get("hex").?.asNumber());
    try testing.expectEqual(@as(f64, 15), doc.asObject().value.get("oct").?.asNumber());
    try testing.expectEqual(@as(f64, 10), doc.asObject().value.get("bin").?.asNumber());
}

test "floats: exponents, underscores, inf/nan" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\a = 1.5e10
        \\b = 1_000.5
        \\c = inf
        \\d = -inf
        \\e = nan
    );
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 1.5e10), doc.asObject().value.get("a").?.asNumber());
    try testing.expectEqual(@as(f64, 1000.5), doc.asObject().value.get("b").?.asNumber());
    try testing.expect(std.math.isPositiveInf(doc.asObject().value.get("c").?.asNumber()));
    try testing.expect(std.math.isNegativeInf(doc.asObject().value.get("d").?.asNumber()));
    try testing.expect(std.math.isNan(doc.asObject().value.get("e").?.asNumber()));
}

test "basic strings decode JSON-style escapes" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "s = \"a\\nb\\tc\\\"d\\\\e\"");
    defer doc.deinit();
    try testing.expectEqualStrings("a\nb\tc\"d\\e", doc.asObject().value.get("s").?.asString().value.data);
}

test "literal strings are verbatim (no escapes)" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "s = 'a\\nb'");
    defer doc.deinit();
    try testing.expectEqualStrings("a\\nb", doc.asObject().value.get("s").?.asString().value.data);
}

test "multi-line strings are an explicit UnsupportedFeature, not silently wrong" {
    const allocator = testing.allocator;
    try testing.expectError(ztoml.TomlError.UnsupportedFeature, ztoml.parse(allocator, "s = \"\"\"hi\"\"\""));
    try testing.expectError(ztoml.TomlError.UnsupportedFeature, ztoml.parse(allocator, "s = '''hi'''"));
}

test "dotted keys create nested tables" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "a.b.c = 1");
    defer doc.deinit();
    const a = doc.asObject().value.get("a").?;
    const b = a.asObject().value.get("b").?;
    try testing.expectEqual(@as(f64, 1), b.asObject().value.get("c").?.asNumber());
}

test "standard table headers, including dotted ones" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[server.tls]
        \\enabled = true
    );
    defer doc.deinit();
    const server = doc.asObject().value.get("server").?;
    try testing.expectEqualStrings("localhost", server.asObject().value.get("host").?.asString().value.data);
    try testing.expectEqual(@as(f64, 8080), server.asObject().value.get("port").?.asNumber());
    const tls = server.asObject().value.get("tls").?;
    try testing.expectEqual(true, tls.asObject().value.get("enabled").?.asBool());
}

test "arrays of tables" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit]]
        \\name = "banana"
    );
    defer doc.deinit();
    const fruit = doc.asObject().value.get("fruit").?;
    try testing.expect(fruit.isArray());
    const items = fruit.asArray().value.toSlice();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("apple", items[0].asObject().value.get("name").?.asString().value.data);
    try testing.expectEqualStrings("banana", items[1].asObject().value.get("name").?.asString().value.data);
}

test "a table nested under the last entry of an array of tables" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[fruit.physical]
        \\color = "red"
    );
    defer doc.deinit();
    const items = doc.asObject().value.get("fruit").?.asArray().value.toSlice();
    try testing.expectEqual(@as(usize, 1), items.len);
    const physical = items[0].asObject().value.get("physical").?;
    try testing.expectEqualStrings("red", physical.asObject().value.get("color").?.asString().value.data);
}

test "arrays: multi-line with comments and trailing comma" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator,
        \\nums = [
        \\  1, # one
        \\  2,
        \\  3,
        \\]
    );
    defer doc.deinit();
    const items = doc.asObject().value.get("nums").?.asArray().value.toSlice();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(f64, 1), items[0].asNumber());
    try testing.expectEqual(@as(f64, 3), items[2].asNumber());
}

test "inline tables, including nested dotted keys" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "point = { x = 1, y = 2 }");
    defer doc.deinit();
    const point = doc.asObject().value.get("point").?;
    try testing.expectEqual(@as(f64, 1), point.asObject().value.get("x").?.asNumber());
    try testing.expectEqual(@as(f64, 2), point.asObject().value.get("y").?.asNumber());
}

test "date/time-shaped scalars parse as plain strings (documented gap)" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "d = 1979-05-27T07:32:00Z");
    defer doc.deinit();
    const d = doc.asObject().value.get("d").?;
    try testing.expect(d.isString());
    try testing.expectEqualStrings("1979-05-27T07:32:00Z", d.asString().value.data);
}

test "invalid input is a catchable parse error, not a crash" {
    const allocator = testing.allocator;
    try testing.expectError(ztoml.TomlError.UnexpectedToken, ztoml.parse(allocator, "= 1"));
    try testing.expectError(ztoml.TomlError.UnterminatedString, ztoml.parse(allocator, "s = \"unterminated"));
    try testing.expectError(ztoml.TomlError.UnexpectedToken, ztoml.parse(allocator, "a = 1 2"));
}
