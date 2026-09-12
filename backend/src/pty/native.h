#ifndef VIVI_PTY_NATIVE_H
#define VIVI_PTY_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef struct vivi_pty_endpoint {
    intptr_t values[8];
} vivi_pty_endpoint_t;

enum {
    VIVI_PTY_EXIT_CODE = 1,
    VIVI_PTY_EXIT_SIGNAL = 2,
    VIVI_PTY_EXIT_TERMINATED = 3,
    VIVI_PTY_EXIT_UNKNOWN = 4,
};

int vivi_pty_spawn(
    const char *cwd,
    const char *command,
    uint16_t rows,
    uint16_t columns,
    vivi_pty_endpoint_t *endpoint
);
intptr_t vivi_pty_read(
    vivi_pty_endpoint_t *endpoint,
    void *buffer,
    size_t length
);
int vivi_pty_write_all(
    vivi_pty_endpoint_t *endpoint,
    const void *buffer,
    size_t length
);
int vivi_pty_terminate(vivi_pty_endpoint_t *endpoint, uint32_t grace_ms);
int vivi_pty_wait(
    vivi_pty_endpoint_t *endpoint,
    int *kind,
    uint32_t *value
);
void vivi_pty_close(vivi_pty_endpoint_t *endpoint);

#endif
