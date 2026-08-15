// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const task_mod = @import("../core/task.zig");

pub fn wakeTask(t: *task_mod.Task) void {
    task_mod.wakeTask(t);
}
