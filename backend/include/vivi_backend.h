#ifndef VIVI_BACKEND_H
#define VIVI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VIVI_BACKEND_ABI_VERSION 3

typedef enum vivi_backend_result {
    VIVI_BACKEND_OK = 0,
    VIVI_BACKEND_INVALID_ARGUMENT = 1,
    VIVI_BACKEND_NO_EVENT = 2,
    VIVI_BACKEND_BUFFER_TOO_SMALL = 3,
    VIVI_BACKEND_BUSY = 4,
    VIVI_BACKEND_STOPPING = 5,
    VIVI_BACKEND_CLOSED = 6,
    VIVI_BACKEND_FAILED = 7,
} vivi_backend_result_t;

typedef struct vivi_backend_conversation vivi_backend_conversation_t;

/* The callback may run on a backend thread. It must only schedule a drain. */
typedef void (*vivi_backend_wake_fn)(void *context);

typedef enum vivi_backend_copilot_cli_launch {
    VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT = 0,
    VIVI_BACKEND_COPILOT_CLI_SEARCH_PROCESS_PATH = 1,
} vivi_backend_copilot_cli_launch_t;

typedef struct vivi_backend_conversation_options {
    const uint8_t *working_directory;
    uint32_t working_directory_length;
    vivi_backend_copilot_cli_launch_t copilot_cli_launch;
    vivi_backend_wake_fn wake;
    void *wake_context;
} vivi_backend_conversation_options_t;

typedef enum vivi_backend_event_kind {
    VIVI_BACKEND_EVENT_READY = 1,
    VIVI_BACKEND_EVENT_STATUS = 2,
    VIVI_BACKEND_EVENT_ASSISTANT_STARTED = 3,
    VIVI_BACKEND_EVENT_ASSISTANT_DELTA = 4,
    VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE = 5,
    VIVI_BACKEND_EVENT_IDLE = 6,
    VIVI_BACKEND_EVENT_FAILURE = 7,
    VIVI_BACKEND_EVENT_CLOSED = 8,
} vivi_backend_event_kind_t;

typedef enum vivi_backend_content_kind {
    VIVI_BACKEND_CONTENT_NONE = 0,
    VIVI_BACKEND_CONTENT_TEXT = 1,
} vivi_backend_content_kind_t;

typedef struct vivi_backend_event {
    vivi_backend_event_kind_t kind;
    vivi_backend_content_kind_t content_kind;
    uint32_t content_length;
} vivi_backend_event_t;

/* Open and submit copy their input bytes before returning. */
vivi_backend_result_t vivi_backend_open(
    const vivi_backend_conversation_options_t *options,
    vivi_backend_conversation_t **out_conversation);
vivi_backend_result_t vivi_backend_submit(
    vivi_backend_conversation_t *conversation,
    const uint8_t *prompt,
    uint32_t prompt_length);
vivi_backend_result_t vivi_backend_next_event(
    vivi_backend_conversation_t *conversation,
    vivi_backend_event_t *out_event,
    uint8_t *content,
    uint32_t content_capacity);
vivi_backend_result_t vivi_backend_close(
    vivi_backend_conversation_t *conversation);
/*
 * The caller serializes operations for one conversation. Close is idempotent
 * and nonblocking. Destroy joins the worker and prevents later wake callbacks.
 */
void vivi_backend_destroy(vivi_backend_conversation_t *conversation);

#ifdef __cplusplus
}
#endif

#endif
