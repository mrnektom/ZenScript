const std = @import("std");

fn clampPos(source: []const u8, pos: usize) usize {
    if (source.len == 0) return 0;
    return @min(pos, source.len - 1);
}

pub fn computeSourceLine(source: []const u8, pos: usize) []const u8 {
    if (source.len == 0) return "";
    const p = clampPos(source, pos);

    // Find the start of the current line (scan backwards for '\n')
    var startPos: usize = 0;
    if (p > 0) {
        for (1..p + 1) |c| {
            if (source[p - c] == '\n') {
                startPos = p - c + 1;
                break;
            }
        }
    }

    // Find the end of the current line (scan forwards for '\n')
    var endPos = source.len;
    for (p..source.len) |i| {
        if (source[i] == '\n') {
            endPos = i;
            break;
        }
    }

    return source[startPos..endPos];
}

pub fn computeLineOffset(source: []const u8, pos: usize) usize {
    if (source.len == 0) return 0;
    const p = clampPos(source, pos);

    // Find the start of the current line (scan backwards for '\n')
    var startPos: usize = 0;
    if (p > 0) {
        for (1..p + 1) |c| {
            if (source[p - c] == '\n') {
                startPos = p - c + 1;
                break;
            }
        }
    }

    return p - startPos;
}

pub fn computeLineNumber(source: []const u8, pos: usize) usize {
    if (source.len == 0) return 0;
    const p = clampPos(source, pos);
    var number: usize = 0;
    for (0..p + 1) |c| {
        if (source[p - c] == '\n') {
            number += 1;
        }
    }

    return number;
}
