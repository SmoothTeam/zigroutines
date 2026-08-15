// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#ifndef ZIGROUTINES_H
#define ZIGROUTINES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

unsigned zr_version_major(void);
unsigned zr_version_minor(void);
unsigned zr_version_patch(void);

typedef struct zr_runtime zr_runtime;
typedef struct zr_channel zr_channel;
typedef void (*zr_task_fn)(void *userdata);

zr_runtime *zr_runtime_create(unsigned workers);
void zr_runtime_destroy(zr_runtime *rt);
int zr_runtime_run(zr_runtime *rt);
int zr_spawn(zr_runtime *rt, zr_task_fn fn, void *userdata);
void zr_yield(void);
void zr_sleep_ns(uint64_t ns);

zr_channel *zr_channel_create(size_t capacity);
void zr_channel_destroy(zr_channel *ch);
void zr_channel_close(zr_channel *ch);
int zr_channel_send(zr_channel *ch, uintptr_t value);
int zr_channel_recv(zr_channel *ch, uintptr_t *out);
int zr_channel_try_send(zr_channel *ch, uintptr_t value);
int zr_channel_try_recv(zr_channel *ch, uintptr_t *out);

#ifdef __cplusplus
}
#endif

#endif
