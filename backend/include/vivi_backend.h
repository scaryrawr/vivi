#ifndef VIVI_BACKEND_H
#define VIVI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VIVI_BACKEND_ABI_VERSION 8
#define VIVI_BACKEND_SESSION_TITLE_MAX_CHARACTERS 80

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
    VIVI_BACKEND_COPILOT_CLI_EXPLICIT_PATH = 1,
} vivi_backend_copilot_cli_launch_t;

typedef struct vivi_backend_conversation_options {
    uint32_t abi_version;
    uint32_t struct_size;
    const uint8_t *working_directory;
    uint32_t working_directory_length;
    const uint8_t *settings_path;
    uint32_t settings_path_length;
    const uint8_t *copilot_cli_path;
    uint32_t copilot_cli_path_length;
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
    VIVI_BACKEND_EVENT_SESSION_TITLE = 9,
    VIVI_BACKEND_EVENT_REASONING_DELTA = 10,
    VIVI_BACKEND_EVENT_REASONING_COMPLETE = 11,
    VIVI_BACKEND_EVENT_MODEL_CATALOG = 12,
    VIVI_BACKEND_EVENT_MODEL_CATALOG_FAILURE = 13,
    VIVI_BACKEND_EVENT_MODEL_SWITCH = 14,
    VIVI_BACKEND_EVENT_TOOL_STARTED = 15,
    VIVI_BACKEND_EVENT_TOOL_FINISHED = 16,
} vivi_backend_event_kind_t;

typedef enum vivi_backend_content_kind {
    VIVI_BACKEND_CONTENT_NONE = 0,
    VIVI_BACKEND_CONTENT_TEXT = 1,
    VIVI_BACKEND_CONTENT_MODEL_CATALOG = 2,
    VIVI_BACKEND_CONTENT_MODEL_SWITCH = 3,
    VIVI_BACKEND_CONTENT_TOOL = 4,
} vivi_backend_content_kind_t;

typedef enum vivi_backend_tool_result {
    VIVI_BACKEND_TOOL_RESULT_NONE = 0,
    VIVI_BACKEND_TOOL_RESULT_RUNNING = 1,
    VIVI_BACKEND_TOOL_RESULT_SUCCEEDED = 2,
    VIVI_BACKEND_TOOL_RESULT_FAILED = 3,
    VIVI_BACKEND_TOOL_RESULT_IMAGE = 4,
} vivi_backend_tool_result_t;

typedef enum vivi_backend_reasoning_effort {
    VIVI_BACKEND_REASONING_NONE = -1,
    VIVI_BACKEND_REASONING_OFF = 0,
    VIVI_BACKEND_REASONING_LOW = 1,
    VIVI_BACKEND_REASONING_MEDIUM = 2,
    VIVI_BACKEND_REASONING_HIGH = 3,
    VIVI_BACKEND_REASONING_XHIGH = 4,
    VIVI_BACKEND_REASONING_MAX = 5,
} vivi_backend_reasoning_effort_t;

typedef enum vivi_backend_model_switch_outcome {
    VIVI_BACKEND_MODEL_SWITCH_NONE = 0,
    VIVI_BACKEND_MODEL_SWITCH_UNCHANGED = 1,
    VIVI_BACKEND_MODEL_SWITCH_DEFAULT_UPDATED = 2,
    VIVI_BACKEND_MODEL_SWITCH_SWITCHED = 3,
    VIVI_BACKEND_MODEL_SWITCH_FAILED = 4,
} vivi_backend_model_switch_outcome_t;

typedef enum vivi_backend_history_effect {
    VIVI_BACKEND_HISTORY_NONE = 0,
    VIVI_BACKEND_HISTORY_PRESERVED = 1,
    VIVI_BACKEND_HISTORY_RESET_VISIBLE_TRANSCRIPT_PRESERVED = 2,
} vivi_backend_history_effect_t;

typedef struct vivi_backend_span {
    uint32_t offset;
    uint32_t length;
} vivi_backend_span_t;

typedef enum vivi_backend_presentation_kind {
    VIVI_BACKEND_PRESENTATION_NONE = 0,
    VIVI_BACKEND_PRESENTATION_LITERAL = 1,
    VIVI_BACKEND_PRESENTATION_MARKDOWN = 2,
    VIVI_BACKEND_PRESENTATION_SOURCE = 3,
} vivi_backend_presentation_kind_t;

typedef enum vivi_backend_language {
    VIVI_BACKEND_LANGUAGE_NONE = 0,
    VIVI_BACKEND_LANGUAGE_ZIG = 1,
    VIVI_BACKEND_LANGUAGE_BASH = 2,
    VIVI_BACKEND_LANGUAGE_JSON = 3,
    VIVI_BACKEND_LANGUAGE_YAML = 4,
    VIVI_BACKEND_LANGUAGE_DIFF = 5,
    VIVI_BACKEND_LANGUAGE_JAVASCRIPT = 6,
    VIVI_BACKEND_LANGUAGE_TYPESCRIPT = 7,
    VIVI_BACKEND_LANGUAGE_TSX = 8,
    VIVI_BACKEND_LANGUAGE_RUST = 9,
    VIVI_BACKEND_LANGUAGE_C = 10,
    VIVI_BACKEND_LANGUAGE_CPP = 11,
    VIVI_BACKEND_LANGUAGE_GO = 12,
    VIVI_BACKEND_LANGUAGE_JAVA = 13,
    VIVI_BACKEND_LANGUAGE_LUA = 14,
    VIVI_BACKEND_LANGUAGE_PYTHON = 15,
} vivi_backend_language_t;

typedef enum vivi_backend_semantic_token {
    VIVI_BACKEND_TOKEN_COMMENT = 1,
    VIVI_BACKEND_TOKEN_STRING = 2,
    VIVI_BACKEND_TOKEN_NUMBER = 3,
    VIVI_BACKEND_TOKEN_CONSTANT = 4,
    VIVI_BACKEND_TOKEN_KEYWORD = 5,
    VIVI_BACKEND_TOKEN_FUNCTION = 6,
    VIVI_BACKEND_TOKEN_PROPERTY = 7,
    VIVI_BACKEND_TOKEN_OPERATOR = 8,
    VIVI_BACKEND_TOKEN_INSERTED = 9,
    VIVI_BACKEND_TOKEN_DELETED = 10,
    VIVI_BACKEND_TOKEN_META = 11,
} vivi_backend_semantic_token_t;

typedef struct vivi_backend_semantic_span {
    vivi_backend_span_t bytes;
    vivi_backend_semantic_token_t token;
    uint32_t reserved;
} vivi_backend_semantic_span_t;

typedef struct vivi_backend_presentation {
    vivi_backend_span_t content;
    vivi_backend_presentation_kind_t kind;
    vivi_backend_language_t language;
    uint32_t semantic_span_offset;
    uint32_t semantic_span_count;
    uint32_t reserved;
} vivi_backend_presentation_t;

typedef struct vivi_backend_model {
    vivi_backend_span_t id;
    vivi_backend_span_t display_name;
    uint64_t max_context_window_tokens;
    uint64_t max_output_tokens;
    uint8_t supports_vision;
    uint8_t reasoning_mask;
    int8_t advertised_default_reasoning;
    uint8_t reserved;
} vivi_backend_model_t;

typedef struct vivi_backend_event {
    vivi_backend_event_kind_t kind;
    vivi_backend_content_kind_t content_kind;
    uint32_t byte_count;
    uint32_t model_count;
    uint32_t semantic_span_count;
    vivi_backend_span_t content;
    vivi_backend_span_t selected_model_id;
    vivi_backend_span_t tool_call_id;
    vivi_backend_span_t tool_title;
    vivi_backend_span_t tool_detail;
    vivi_backend_span_t tool_input;
    vivi_backend_presentation_t tool_input_presentation;
    vivi_backend_presentation_t tool_output_presentation;
    vivi_backend_tool_result_t tool_result;
    vivi_backend_reasoning_effort_t selected_reasoning;
    vivi_backend_model_switch_outcome_t switch_outcome;
    vivi_backend_history_effect_t history_effect;
    uint8_t default_saved;
    uint8_t cleanup_failed;
    uint16_t reserved;
} vivi_backend_event_t;

/* Open and submit copy their input bytes before returning. */
vivi_backend_result_t vivi_backend_open(
    const vivi_backend_conversation_options_t *options,
    vivi_backend_conversation_t **out_conversation);
vivi_backend_result_t vivi_backend_submit(
    vivi_backend_conversation_t *conversation,
    const uint8_t *prompt,
    uint32_t prompt_length);
vivi_backend_result_t vivi_backend_refresh_models(
    vivi_backend_conversation_t *conversation);
vivi_backend_result_t vivi_backend_switch_model(
    vivi_backend_conversation_t *conversation,
    const uint8_t *model_id,
    uint32_t model_id_length,
    vivi_backend_reasoning_effort_t reasoning);
/*
 * Sanitizes untrusted tool text for Markdown display. out_length always receives
 * the required byte count. A short or null output buffer does not write output.
 */
vivi_backend_result_t vivi_backend_sanitize_tool_markdown(
    const uint8_t *input,
    uint32_t input_length,
    uint8_t *output,
    uint32_t output_capacity,
    uint32_t *out_length);
/*
 * Presents one fenced code fragment. The probe reports required byte/span
 * counts and descriptor metadata. A short buffer writes neither buffer.
 */
vivi_backend_result_t vivi_backend_present_code_fragment(
    const uint8_t *language_name,
    uint32_t language_name_length,
    const uint8_t *input,
    uint32_t input_length,
    vivi_backend_presentation_t *out_presentation,
    uint8_t *output,
    uint32_t output_capacity,
    vivi_backend_semantic_span_t *semantic_spans,
    uint32_t semantic_span_capacity);
/*
 * next_event always fills out_event for a pending event. If either caller-owned
 * buffer is too small it returns BUFFER_TOO_SMALL without writing any buffer
 * or consuming the event; count fields report required capacities.
 * Every span is relative to bytes and is valid only for the completed call.
 */
vivi_backend_result_t vivi_backend_next_event(
    vivi_backend_conversation_t *conversation,
    vivi_backend_event_t *out_event,
    uint8_t *bytes,
    uint32_t byte_capacity,
    vivi_backend_model_t *models,
    uint32_t model_capacity,
    vivi_backend_semantic_span_t *semantic_spans,
    uint32_t semantic_span_capacity);
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
