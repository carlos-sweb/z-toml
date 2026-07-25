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
    try testing.expect(doc == .object);
    try testing.expectEqualStrings("app", doc.object.value.get("name").?.string.value.data);
    try testing.expectEqual(@as(f64, 8080), doc.object.value.get("port").?.number);
    try testing.expectEqual(@as(f64, 3.14), doc.object.value.get("ratio").?.number);
    try testing.expectEqual(true, doc.object.value.get("active").?.boolean);
    try testing.expectEqual(false, doc.object.value.get("disabled").?.boolean);
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
    try testing.expectEqual(@as(f64, 1), doc.object.value.get("a").?.number);
    try testing.expectEqual(@as(f64, 2), doc.object.value.get("b").?.number);
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
    try testing.expectEqual(@as(f64, 1000000), doc.object.value.get("decimal").?.number);
    try testing.expectEqual(@as(f64, -42), doc.object.value.get("neg").?.number);
    try testing.expectEqual(@as(f64, 255), doc.object.value.get("hex").?.number);
    try testing.expectEqual(@as(f64, 15), doc.object.value.get("oct").?.number);
    try testing.expectEqual(@as(f64, 10), doc.object.value.get("bin").?.number);
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
    try testing.expectEqual(@as(f64, 1.5e10), doc.object.value.get("a").?.number);
    try testing.expectEqual(@as(f64, 1000.5), doc.object.value.get("b").?.number);
    try testing.expect(std.math.isPositiveInf(doc.object.value.get("c").?.number));
    try testing.expect(std.math.isNegativeInf(doc.object.value.get("d").?.number));
    try testing.expect(std.math.isNan(doc.object.value.get("e").?.number));
}

test "basic strings decode JSON-style escapes" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "s = \"a\\nb\\tc\\\"d\\\\e\"");
    defer doc.deinit();
    try testing.expectEqualStrings("a\nb\tc\"d\\e", doc.object.value.get("s").?.string.value.data);
}

test "literal strings are verbatim (no escapes)" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "s = 'a\\nb'");
    defer doc.deinit();
    try testing.expectEqualStrings("a\\nb", doc.object.value.get("s").?.string.value.data);
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
    const a = doc.object.value.get("a").?;
    const b = a.object.value.get("b").?;
    try testing.expectEqual(@as(f64, 1), b.object.value.get("c").?.number);
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
    const server = doc.object.value.get("server").?;
    try testing.expectEqualStrings("localhost", server.object.value.get("host").?.string.value.data);
    try testing.expectEqual(@as(f64, 8080), server.object.value.get("port").?.number);
    const tls = server.object.value.get("tls").?;
    try testing.expectEqual(true, tls.object.value.get("enabled").?.boolean);
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
    const fruit = doc.object.value.get("fruit").?;
    try testing.expect(fruit == .array);
    const items = fruit.array.value.toSlice();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("apple", items[0].object.value.get("name").?.string.value.data);
    try testing.expectEqualStrings("banana", items[1].object.value.get("name").?.string.value.data);
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
    const items = doc.object.value.get("fruit").?.array.value.toSlice();
    try testing.expectEqual(@as(usize, 1), items.len);
    const physical = items[0].object.value.get("physical").?;
    try testing.expectEqualStrings("red", physical.object.value.get("color").?.string.value.data);
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
    const items = doc.object.value.get("nums").?.array.value.toSlice();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(f64, 1), items[0].number);
    try testing.expectEqual(@as(f64, 3), items[2].number);
}

test "inline tables, including nested dotted keys" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "point = { x = 1, y = 2 }");
    defer doc.deinit();
    const point = doc.object.value.get("point").?;
    try testing.expectEqual(@as(f64, 1), point.object.value.get("x").?.number);
    try testing.expectEqual(@as(f64, 2), point.object.value.get("y").?.number);
}

test "date/time-shaped scalars parse as plain strings (documented gap)" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, "d = 1979-05-27T07:32:00Z");
    defer doc.deinit();
    const d = doc.object.value.get("d").?;
    try testing.expect(d == .string);
    try testing.expectEqualStrings("1979-05-27T07:32:00Z", d.string.value.data);
}

test "invalid input is a catchable parse error, not a crash" {
    const allocator = testing.allocator;
    try testing.expectError(ztoml.TomlError.UnexpectedToken, ztoml.parse(allocator, "= 1"));
    try testing.expectError(ztoml.TomlError.UnterminatedString, ztoml.parse(allocator, "s = \"unterminated"));
    try testing.expectError(ztoml.TomlError.UnexpectedToken, ztoml.parse(allocator, "a = 1 2"));
}
