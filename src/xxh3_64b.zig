//! The implementation of XXH3_64bits
//!
//! See "xxh3-64b-ref.c" in the "clean" C implementation for details.
const std = @import("std");

pub const HashResult = u64;

const STRIPE_LEN = 64;
// nb of secret bytes consumed at each accumulation 
const XXH_SECRET_CONSUME_RATE = 8;
const ACC_NB = (STRIPE_LEN / @sizeOf(u64));

/// Mixes up the hash to finalize 
fn avalanche(original_hash: u64) HashResult {
    var hash = original_hash;
    hash ^= hash >> 37;
    hash *%= 0x165667919E3779F9ULL;
    hash ^= hash >> 32;
    return hash;
}


//
// boring hash constants
//

const PRIME32_1: u32 = 0x9E3779B1;
const PRIME32_2: u32 = 0x85EBCA77;
const PRIME32_3: u32 = 0xC2B2AE3D;

const PRIME64_1: u64 = 0x9E3779B185EBCA87;
const PRIME64_2: u64 = 0xC2B2AE3D27D4EB4F;
const PRIME64_3: u64 = 0x165667B19E3779F9;
const PRIME64_4: u64 = 0x85EBCA77C2B2AE63;
const PRIME64_5: u64 = 0x27D4EB2F165667C5;

const XXH_SECRET_DEFAULT_SIZE = 192;
const kSecret: [XXH_SECRET_DEFAULT_SIZE]const u8 = {
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,

    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
};

// Support functions for C code (mostly bit manipulation)
//
// Most of these are super boring, because Zig includes these
// bit manipulations in the stdlib (or as intrinsics).
//
// I include these wrapper  for consistency with the C implementation :)

/// Calculates a 64-bit to 128-bit unsigned multiply,
/// then xor's the low bits of the product with
/// the high bits for a 64-bit result.
fn mul128_fold64(lhs: u64, rhs: u64) {
    // Rely on zig for u128 multiply support
    //
    // The C implementation usually uses emulation of this,
    // however Zig has compiler support for u128
    //
    // Most architectures have a "multiply high" and "multiply low"
    // instructions so 128-bit multiply is extremely cheep with compiler support
    //
    // If architecture/compiler don't have these instructions,
    // then our emulation is not going to beat `compiler_rt`
    const product: u128 = @as(u128, lhs) * @as(u128, rhs);
    const low = @truncate(u64, product);
    const high = @truncate(u64, product >> 64);
    return low ^ high;
}

/// Portably reads a 32-bit little endian integer from p.
fn read_u32(bytes: *const [4]u8) u32 {
    return std.mem.readIntLittle(u32, bytes);
}

/// Portably reads a 64-bit little endian integer from p.
fn read_u64(bytes: *const [8]u8) u64 {
    return std.mem.readIntLittle(u64, bytes);
}

// Portably writes a 64-bit little endian integer to p.
fn write_u64(bytes: *const [8]u8, val: u64) {
    std.mem.writeIntLittle(u64, bytes, val);
}

/// 32-bit byteswap
fn swap32(x: u32) u32 {
    return @byteSwap(x);
}

/// 64-bit byteswap
fn swap64(x: u64) u64 {
    return @byteSwap(x);
}

fn rotl64(x: u64, amt: u32) u64 {
    return std.math.rotl(x, amt);
}
