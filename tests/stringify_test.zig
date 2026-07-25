const std = @import("std");
const testing = std.testing;
const ztoml = @import("ztoml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "stringify scalars at the root" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("name", try JSValue.newString(allocator, "app"));
    try obj.object.value.set("port", JSValue.fromNumber(8080));
    try obj.object.value.set("active", JSValue.fromBool(true));

    const out = try ztoml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"app\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = 8080\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "active = true\n") != null);
}

test "stringify a nested object as a [table] section, after root scalars" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("name", try JSValue.newString(allocator, "app"));
    var server = try JSValue.newObject(allocator);
    try server.object.value.set("host", try JSValue.newString(allocator, "localhost"));
    try obj.object.value.set("server", server);

    const out = try ztoml.stringify(allocator, obj);
    defer allocator.free(out);
    const name_at = std.mem.indexOf(u8, out, "name = \"app\"").?;
    const table_at = std.mem.indexOf(u8, out, "[server]").?;
    try testing.expect(name_at < table_at);
    try testing.expect(std.mem.indexOf(u8, out, "host = \"localhost\"") != null);
}

test "stringify an array of objects as [[table]] sections" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    var arr = try JSValue.newArray(allocator);
    var a = try JSValue.newObject(allocator);
    try a.object.value.set("name", try JSValue.newString(allocator, "apple"));
    _ = try arr.array.value.push(a);
    var b = try JSValue.newObject(allocator);
    try b.object.value.set("name", try JSValue.newString(allocator, "banana"));
    _ = try arr.array.value.push(b);
    try obj.object.value.set("fruit", arr);

    const out = try ztoml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[[fruit]]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"apple\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"banana\"") != null);
}

test "stringify an array of scalars inline" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    var arr = try JSValue.newArray(allocator);
    _ = try arr.array.value.push(JSValue.fromNumber(1));
    _ = try arr.array.value.push(JSValue.fromNumber(2));
    try obj.object.value.set("nums", arr);

    const out = try ztoml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("nums = [1, 2]\n", out);
}

test "a non-object top-level value is Unserializable" {
    const allocator = testing.allocator;
    try testing.expectError(ztoml.TomlError.Unserializable, ztoml.stringify(allocator, JSValue.fromNumber(1)));
}

test "undefined/function object properties are omitted, matching JSON.stringify" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("a", JSValue.fromNumber(1));
    try obj.object.value.set("skip", JSValue.UNDEFINED);

    const out = try ztoml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("a = 1\n", out);
}
