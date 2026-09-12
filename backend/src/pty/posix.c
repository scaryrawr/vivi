#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "native.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__) && !defined(SO_NOSIGPIPE)
#define SO_NOSIGPIPE 0x1022
#endif

enum { STATUS_READY = 1, STATUS_EXIT = 2, STATUS_ERROR = 3 };

typedef struct status_record {
    int kind;
    int exit_kind;
    uint32_t value;
} status_record_t;

static int write_record(int fd, const status_record_t *record) {
    const unsigned char *cursor = (const unsigned char *)record;
    size_t remaining = sizeof(*record);
    while (remaining != 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return 0;
}

static int read_record(int fd, status_record_t *record) {
    unsigned char *cursor = (unsigned char *)record;
    size_t remaining = sizeof(*record);
    while (remaining != 0) {
        ssize_t amount = read(fd, cursor, remaining);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return -1;
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    return 0;
}

static void sleep_ms(uint32_t milliseconds) {
    struct timespec request;
    request.tv_sec = (time_t)(milliseconds / 1000);
    request.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
    while (nanosleep(&request, &request) < 0 && errno == EINTR) {}
}

static status_record_t exit_record(int status, int terminated) {
    status_record_t record;
    record.kind = STATUS_EXIT;
    record.value = 0;
    if (terminated) {
        record.exit_kind = VIVI_PTY_EXIT_TERMINATED;
    } else if (WIFEXITED(status)) {
        record.exit_kind = VIVI_PTY_EXIT_CODE;
        record.value = (uint32_t)WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        record.exit_kind = VIVI_PTY_EXIT_SIGNAL;
        record.value = (uint32_t)WTERMSIG(status);
    } else {
        record.exit_kind = VIVI_PTY_EXIT_UNKNOWN;
    }
    return record;
}

static int wait_for_child(pid_t child, int *status, uint32_t milliseconds) {
    uint32_t waited = 0;
    while (waited <= milliseconds) {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child) return 1;
        if (result < 0 && errno != EINTR) return -1;
        sleep_ms(10);
        waited += 10;
    }
    return 0;
}

static void supervise(
    int slave_fd,
    int control_fd,
    int status_fd,
    const char *cwd,
    const char *command
) {
    int ready_pipe[2];
    if (pipe(ready_pipe) != 0) {
        status_record_t error_record = { STATUS_ERROR, 0, (uint32_t)errno };
        (void)write_record(status_fd, &error_record);
        _exit(125);
    }

    pid_t child = fork();
    if (child < 0) {
        status_record_t error_record = { STATUS_ERROR, 0, (uint32_t)errno };
        (void)write_record(status_fd, &error_record);
        _exit(125);
    }
    if (child == 0) {
        unsigned char ready = 0;
        close(ready_pipe[0]);
        close(control_fd);
        close(status_fd);
        if (setsid() < 0) goto child_failed;
        if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) goto child_failed;
        if (dup2(slave_fd, STDIN_FILENO) < 0) goto child_failed;
        if (dup2(slave_fd, STDOUT_FILENO) < 0) goto child_failed;
        if (dup2(slave_fd, STDERR_FILENO) < 0) goto child_failed;
        if (slave_fd > STDERR_FILENO) close(slave_fd);
        if (chdir(cwd) != 0) goto child_failed;
        ready = 1;
        (void)write(ready_pipe[1], &ready, 1);
        close(ready_pipe[1]);
        execlp(
            "bash",
            "bash",
            "--noprofile",
            "--norc",
            "-i",
            "+m",
            "-c",
            command,
            (char *)NULL
        );
child_failed:
        (void)write(ready_pipe[1], &ready, 1);
        _exit(126);
    }

    close(ready_pipe[1]);
    close(slave_fd);
    unsigned char ready = 0;
    ssize_t ready_count;
    do {
        ready_count = read(ready_pipe[0], &ready, 1);
    } while (ready_count < 0 && errno == EINTR);
    close(ready_pipe[0]);
    if (ready_count != 1 || ready != 1) {
        int status = 0;
        (void)waitpid(child, &status, 0);
        status_record_t error_record = { STATUS_ERROR, 0, (uint32_t)ECHILD };
        (void)write_record(status_fd, &error_record);
        _exit(125);
    }

    status_record_t ready_record = { STATUS_READY, 0, (uint32_t)child };
    if (write_record(status_fd, &ready_record) != 0) {
        kill(-child, SIGKILL);
        (void)waitpid(child, NULL, 0);
        _exit(125);
    }

    int status = 0;
    int terminated = 0;
    for (;;) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) break;
        if (waited < 0 && errno != EINTR) {
            status = 0;
            break;
        }

        struct pollfd descriptor;
        descriptor.fd = control_fd;
        descriptor.events = POLLIN | POLLHUP | POLLERR;
        descriptor.revents = 0;
        int polled;
        do {
            polled = poll(&descriptor, 1, 25);
        } while (polled < 0 && errno == EINTR);
        if (polled > 0 && descriptor.revents != 0) {
            uint32_t grace_ms = 750;
            (void)read(control_fd, &grace_ms, sizeof(grace_ms));
            terminated = 1;
            kill(-child, SIGHUP);
            if (wait_for_child(child, &status, grace_ms / 2) == 1) break;
            kill(-child, SIGTERM);
            if (wait_for_child(child, &status, grace_ms / 2) == 1) break;
            kill(-child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            break;
        }
    }

    if (!terminated) {
        kill(-child, SIGHUP);
        sleep_ms(25);
        kill(-child, SIGTERM);
        sleep_ms(25);
    }
    kill(-child, SIGKILL);
    status_record_t record = exit_record(status, terminated);
    (void)write_record(status_fd, &record);
    close(control_fd);
    close(status_fd);
    _exit(0);
}

int vivi_pty_spawn(
    const char *cwd,
    const char *command,
    uint16_t rows,
    uint16_t columns,
    vivi_pty_endpoint_t *endpoint
) {
    int master_fd = -1;
    int slave_fd = -1;
    int control[2] = { -1, -1 };
    int status[2] = { -1, -1 };
    struct winsize size;
    memset(endpoint, 0xff, sizeof(*endpoint));
    memset(&size, 0, sizeof(size));
    size.ws_row = rows;
    size.ws_col = columns;

    if (openpty(&master_fd, &slave_fd, NULL, NULL, &size) != 0) goto failed;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, control) != 0) goto failed;
#if defined(__APPLE__)
    {
        int enabled = 1;
        if (setsockopt(
            control[1],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            sizeof(enabled)
        ) != 0) goto failed;
    }
#endif
    if (pipe(status) != 0) goto failed;

    pid_t supervisor = fork();
    if (supervisor < 0) goto failed;
    if (supervisor == 0) {
        close(master_fd);
        close(control[1]);
        close(status[0]);
        supervise(slave_fd, control[0], status[1], cwd, command);
    }

    close(slave_fd);
    slave_fd = -1;
    close(control[0]);
    control[0] = -1;
    close(status[1]);
    status[1] = -1;

    status_record_t ready;
    if (read_record(status[0], &ready) != 0 || ready.kind != STATUS_READY) {
        close(master_fd);
        close(control[1]);
        close(status[0]);
        (void)waitpid(supervisor, NULL, 0);
        errno = ECHILD;
        return -1;
    }

    endpoint->values[0] = (intptr_t)master_fd;
    endpoint->values[1] = (intptr_t)control[1];
    endpoint->values[2] = (intptr_t)status[0];
    endpoint->values[3] = (intptr_t)supervisor;
    endpoint->values[4] = (intptr_t)ready.value;
    return 0;

failed:
    {
        int saved = errno;
        if (master_fd >= 0) close(master_fd);
        if (slave_fd >= 0) close(slave_fd);
        if (control[0] >= 0) close(control[0]);
        if (control[1] >= 0) close(control[1]);
        if (status[0] >= 0) close(status[0]);
        if (status[1] >= 0) close(status[1]);
        errno = saved;
        return -1;
    }
}

intptr_t vivi_pty_read(
    vivi_pty_endpoint_t *endpoint,
    void *buffer,
    size_t length
) {
    int fd = (int)endpoint->values[0];
    for (;;) {
        ssize_t amount = read(fd, buffer, length);
        if (amount < 0 && errno == EINTR) continue;
#if defined(__linux__)
        if (amount < 0 && errno == EIO) return 0;
#endif
        return (intptr_t)amount;
    }
}

int vivi_pty_write_all(
    vivi_pty_endpoint_t *endpoint,
    const void *buffer,
    size_t length
) {
    int fd = (int)endpoint->values[0];
    const unsigned char *cursor = (const unsigned char *)buffer;
    while (length != 0) {
        ssize_t amount = write(fd, cursor, length);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return -1;
        cursor += (size_t)amount;
        length -= (size_t)amount;
    }
    return 0;
}

int vivi_pty_terminate(vivi_pty_endpoint_t *endpoint, uint32_t grace_ms) {
    int fd = (int)endpoint->values[1];
    if (fd < 0) return 0;
    endpoint->values[1] = -1;
    const unsigned char *cursor = (const unsigned char *)&grace_ms;
    size_t remaining = sizeof(grace_ms);
    while (remaining != 0) {
        ssize_t amount = send(
            fd,
            cursor,
            remaining,
#if defined(MSG_NOSIGNAL)
            MSG_NOSIGNAL
#else
            0
#endif
        );
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) {
            pid_t child = (pid_t)endpoint->values[4];
            if (child > 0) kill(-child, SIGKILL);
            break;
        }
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    close(fd);
    return 0;
}

int vivi_pty_wait(
    vivi_pty_endpoint_t *endpoint,
    int *kind,
    uint32_t *value
) {
    status_record_t record;
    int fd = (int)endpoint->values[2];
    int valid = read_record(fd, &record) == 0 && record.kind == STATUS_EXIT;
    close(fd);
    endpoint->values[2] = -1;
    pid_t supervisor = (pid_t)endpoint->values[3];
    while (waitpid(supervisor, NULL, 0) < 0 && errno == EINTR) {}
    endpoint->values[3] = -1;
    if (!valid) return -1;
    *kind = record.exit_kind;
    *value = record.value;
    return 0;
}

void vivi_pty_close(vivi_pty_endpoint_t *endpoint) {
    for (int index = 0; index < 3; ++index) {
        int fd = (int)endpoint->values[index];
        if (fd >= 0) close(fd);
        endpoint->values[index] = -1;
    }
}
