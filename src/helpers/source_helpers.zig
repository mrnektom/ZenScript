const std = @import("std");
pub fn computeSourceLine(source: []const u8, pos: usize) []const u8 {
    var startPos: usize = 0;
    var endPos = source.len;
    for (0..pos + 1) |c| {
        if (source[pos - c] == '\n') {
            startPos = pos - c;
            break;
        }
    }

    if (startPos > 0) startPos += 1;

    for (pos..source.len) |i| {
        if (source[i] == '\n') {
            endPos = i;
            break;
        }
    }
    return source[startPos..endPos];
}

pub fn computeLineOffset(source: []const u8, pos: usize) usize {
    var startPos: usize = 0;
    for (0..pos + 1) |c| {
        if (source[pos - c] == '\n') {
            startPos = pos - c + 1;
            break;
        }
    }

    return pos - startPos;
}

pub fn computeLineNumber(source: []const u8, pos: usize) usize {
    var number: usize = 0;
    for (0..pos) |c| {
        if (source[pos - c] == '\n') {
            number += 1;
        }
    }

    return number;
}
