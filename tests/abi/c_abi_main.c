// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#include "zigroutines.h"

static int hits;
static uintptr_t got;

static void yielder(void *ud) {
    (void)ud;
    hits += 1;
    zr_yield();
    hits += 1;
}

static void producer(void *ud) {
    zr_channel *ch = (zr_channel *)ud;
    if (zr_channel_send(ch, 40) != 0) return;
    if (zr_channel_send(ch, 2) != 0) return;
    zr_channel_close(ch);
}

static void consumer(void *ud) {
    zr_channel *ch = (zr_channel *)ud;
    uintptr_t a = 0;
    uintptr_t b = 0;
    if (zr_channel_recv(ch, &a) != 0) return;
    if (zr_channel_recv(ch, &b) != 0) return;
    got = a + b;
}

static void sleeper(void *ud) {
    zr_channel *ch = (zr_channel *)ud;
    if (zr_channel_try_send(ch, 7) != 0) return;
    uintptr_t v = 0;
    if (zr_channel_try_recv(ch, &v) != 0) return;
    zr_sleep_ns(1000);
    if (v == 7) hits = 1;
}

#ifdef __cplusplus
extern "C"
#endif
int c_abi_main(void) {
    if (zr_version_major() != 1) return 1;
    if (zr_version_minor() != 0) return 1;
    if (zr_version_patch() != 0) return 1;

    zr_runtime_destroy(0);
    zr_channel_destroy(0);
    zr_channel_close(0);
    if (zr_runtime_run(0) != -1) return 2;
    if (zr_spawn(0, 0, 0) != -1) return 2;
    if (zr_channel_send(0, 0) != -1) return 2;

    zr_runtime *empty = zr_runtime_create(1);
    if (!empty) return 3;
    if (zr_runtime_run(empty) != 0) {
        zr_runtime_destroy(empty);
        return 3;
    }
    zr_runtime_destroy(empty);

    hits = 0;
    zr_runtime *rt = zr_runtime_create(1);
    if (!rt) return 4;
    if (zr_spawn(rt, yielder, 0) != 0) {
        zr_runtime_destroy(rt);
        return 4;
    }
    if (zr_runtime_run(rt) != 0) {
        zr_runtime_destroy(rt);
        return 4;
    }
    zr_runtime_destroy(rt);
    if (hits != 2) return 5;

    got = 0;
    zr_channel *ch = zr_channel_create(4);
    if (!ch) return 6;
    rt = zr_runtime_create(1);
    if (!rt) {
        zr_channel_destroy(ch);
        return 6;
    }
    if (zr_spawn(rt, producer, ch) != 0 || zr_spawn(rt, consumer, ch) != 0) {
        zr_runtime_destroy(rt);
        zr_channel_destroy(ch);
        return 6;
    }
    if (zr_runtime_run(rt) != 0) {
        zr_runtime_destroy(rt);
        zr_channel_destroy(ch);
        return 6;
    }
    zr_runtime_destroy(rt);
    zr_channel_destroy(ch);
    if (got != 42) return 7;

    hits = 0;
    ch = zr_channel_create(1);
    if (!ch) return 8;
    if (zr_channel_try_send(ch, 1) != 0) {
        zr_channel_destroy(ch);
        return 8;
    }
    if (zr_channel_try_send(ch, 2) != 1) {
        zr_channel_destroy(ch);
        return 8;
    }
    {
        uintptr_t drain = 0;
        if (zr_channel_try_recv(ch, &drain) != 0 || drain != 1) {
            zr_channel_destroy(ch);
            return 8;
        }
    }
    rt = zr_runtime_create(1);
    if (!rt) {
        zr_channel_destroy(ch);
        return 8;
    }
    if (zr_spawn(rt, sleeper, ch) != 0) {
        zr_runtime_destroy(rt);
        zr_channel_destroy(ch);
        return 8;
    }
    if (zr_runtime_run(rt) != 0) {
        zr_runtime_destroy(rt);
        zr_channel_destroy(ch);
        return 8;
    }
    zr_runtime_destroy(rt);
    zr_channel_destroy(ch);
    if (hits != 1) return 9;

    return 0;
}
