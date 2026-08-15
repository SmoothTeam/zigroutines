// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

extern fn c_abi_main() c_int;

pub fn main() u8 {
    const rc = c_abi_main();
    return if (rc < 0) 1 else @intCast(rc);
}
