#ifndef VIVI_BACKEND_H
#define VIVI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VIVI_BACKEND_ABI_VERSION 10

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

typedef enum vivi_backend_canvas_mode {
    VIVI_BACKEND_CANVAS_DISABLED = 0,
    VIVI_BACKEND_CANVAS_ENABLED = 1,
} vivi_backend_canvas_mode_t;

typedef struct vivi_backend_conversation_options {
    uint32_t abi_version;
    uint32_t struct_size;
    const uint8_t *working_directory;
    uint32_t working_directory_length;
    const uint8_t *settings_path;
    uint32_t settings_path_length;
    const uint8_t *sessions_directory;
    uint32_t sessions_directory_length;
    const uint8_t *copilot_cli_path;
    uint32_t copilot_cli_path_length;
    vivi_backend_copilot_cli_launch_t copilot_cli_launch;
    vivi_backend_wake_fn wake;
    void *wake_context;
    vivi_backend_canvas_mode_t canvas_mode;
    uint32_t canvas_options_reserved;
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
    VIVI_BACKEND_EVENT_SESSION_CATALOG = 17,
    VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE = 18,
    VIVI_BACKEND_EVENT_SESSION_TRACKING_FAILURE = 19,
    VIVI_BACKEND_EVENT_SESSION_RESUME = 20,
    VIVI_BACKEND_EVENT_CANVAS_SNAPSHOT = 21,
    VIVI_BACKEND_EVENT_CANVAS_OPERATION = 22,
} vivi_backend_event_kind_t;

typedef enum vivi_backend_content_kind {
    VIVI_BACKEND_CONTENT_NONE = 0,
    VIVI_BACKEND_CONTENT_TEXT = 1,
    VIVI_BACKEND_CONTENT_MODEL_CATALOG = 2,
    VIVI_BACKEND_CONTENT_MODEL_SWITCH = 3,
    VIVI_BACKEND_CONTENT_TOOL = 4,
    VIVI_BACKEND_CONTENT_SESSION_CATALOG = 5,
    VIVI_BACKEND_CONTENT_SESSION_RESUME = 6,
    VIVI_BACKEND_CONTENT_CANVAS_SNAPSHOT = 7,
    VIVI_BACKEND_CONTENT_CANVAS_OPERATION = 8,
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

typedef enum vivi_backend_session_request {
    VIVI_BACKEND_SESSION_REQUEST_LOCAL = 1,
    VIVI_BACKEND_SESSION_REQUEST_ALL = 2,
} vivi_backend_session_request_t;

typedef enum vivi_backend_session_scope {
    VIVI_BACKEND_SESSION_SCOPE_NONE = 0,
    VIVI_BACKEND_SESSION_SCOPE_LOCAL = 1,
    VIVI_BACKEND_SESSION_SCOPE_BROADER = 2,
} vivi_backend_session_scope_t;

typedef enum vivi_backend_session_resume_outcome {
    VIVI_BACKEND_SESSION_RESUME_NONE = 0,
    VIVI_BACKEND_SESSION_RESUME_RESUMED = 1,
    VIVI_BACKEND_SESSION_RESUME_FAILED = 2,
} vivi_backend_session_resume_outcome_t;

typedef enum vivi_backend_transcript_role {
    VIVI_BACKEND_TRANSCRIPT_USER = 1,
    VIVI_BACKEND_TRANSCRIPT_ASSISTANT = 2,
    VIVI_BACKEND_TRANSCRIPT_REASONING = 3,
} vivi_backend_transcript_role_t;

typedef enum vivi_backend_session_flags {
    VIVI_BACKEND_SESSION_TITLE_PRESENT = 1u << 0,
    VIVI_BACKEND_SESSION_SUMMARY_PRESENT = 1u << 1,
    VIVI_BACKEND_SESSION_CURRENT = 1u << 2,
} vivi_backend_session_flags_t;

typedef struct vivi_backend_resume_key {
    uint64_t generation;
    uint32_t slot;
    vivi_backend_session_scope_t scope;
} vivi_backend_resume_key_t;

typedef struct vivi_backend_session_summary {
    vivi_backend_resume_key_t key;
    vivi_backend_span_t working_directory;
    vivi_backend_span_t model_id;
    vivi_backend_span_t title;
    vivi_backend_span_t summary;
    int64_t last_used_unix_ms;
    vivi_backend_reasoning_effort_t reasoning;
    uint32_t flags;
    uint32_t reserved;
} vivi_backend_session_summary_t;

typedef struct vivi_backend_transcript_item {
    vivi_backend_span_t text;
    vivi_backend_transcript_role_t role;
    uint32_t reserved;
} vivi_backend_transcript_item_t;

typedef struct vivi_backend_canvas_key {
    vivi_backend_span_t extension_id;
    vivi_backend_span_t canvas_id;
    vivi_backend_span_t instance_id;
} vivi_backend_canvas_key_t;

typedef enum vivi_backend_canvas_capability {
    VIVI_BACKEND_CANVAS_CAPABILITY_NONE = 0,
    VIVI_BACKEND_CANVAS_CAPABILITY_UNKNOWN = 1,
    VIVI_BACKEND_CANVAS_CAPABILITY_UNSUPPORTED = 2,
    VIVI_BACKEND_CANVAS_CAPABILITY_SUPPORTED = 3,
} vivi_backend_canvas_capability_t;

typedef enum vivi_backend_canvas_runtime {
    VIVI_BACKEND_CANVAS_RUNTIME_NONE = 0,
    VIVI_BACKEND_CANVAS_RUNTIME_CLOSED = 1,
    VIVI_BACKEND_CANVAS_RUNTIME_OPENING = 2,
    VIVI_BACKEND_CANVAS_RUNTIME_OPENED = 3,
    VIVI_BACKEND_CANVAS_RUNTIME_CLOSING = 4,
    VIVI_BACKEND_CANVAS_RUNTIME_UNAVAILABLE = 5,
} vivi_backend_canvas_runtime_t;

typedef enum vivi_backend_canvas_record {
    VIVI_BACKEND_CANVAS_RECORD_NONE = 0,
    VIVI_BACKEND_CANVAS_RECORD_RECORDED = 1,
    VIVI_BACKEND_CANVAS_RECORD_REMOVED = 2,
} vivi_backend_canvas_record_t;

typedef enum vivi_backend_canvas_degradation {
    VIVI_BACKEND_CANVAS_DEGRADATION_NONE = 0,
    VIVI_BACKEND_CANVAS_DEGRADATION_INVALID_SIGNAL = 1,
    VIVI_BACKEND_CANVAS_DEGRADATION_LIMIT_EXCEEDED = 2,
    VIVI_BACKEND_CANVAS_DEGRADATION_BACKPRESSURE = 3,
    VIVI_BACKEND_CANVAS_DEGRADATION_HOST_FAILURE = 4,
} vivi_backend_canvas_degradation_t;

typedef enum vivi_backend_canvas_operation_kind {
    VIVI_BACKEND_CANVAS_OPERATION_NONE = 0,
    VIVI_BACKEND_CANVAS_OPERATION_OPEN = 1,
    VIVI_BACKEND_CANVAS_OPERATION_CLOSE = 2,
    VIVI_BACKEND_CANVAS_OPERATION_INVOKE_ACTION = 3,
} vivi_backend_canvas_operation_kind_t;

typedef enum vivi_backend_canvas_operation_outcome {
    VIVI_BACKEND_CANVAS_OPERATION_OUTCOME_NONE = 0,
    VIVI_BACKEND_CANVAS_OPERATION_SUCCEEDED = 1,
    VIVI_BACKEND_CANVAS_OPERATION_FAILED = 2,
} vivi_backend_canvas_operation_outcome_t;

typedef enum vivi_backend_canvas_operation_failure {
    VIVI_BACKEND_CANVAS_FAILURE_NONE = 0,
    VIVI_BACKEND_CANVAS_FAILURE_DISABLED = 1,
    VIVI_BACKEND_CANVAS_FAILURE_UNSUPPORTED = 2,
    VIVI_BACKEND_CANVAS_FAILURE_UNAVAILABLE = 3,
    VIVI_BACKEND_CANVAS_FAILURE_INVALID_REQUEST = 4,
    VIVI_BACKEND_CANVAS_FAILURE_BACKPRESSURE = 5,
    VIVI_BACKEND_CANVAS_FAILURE_HOST_FAILURE = 6,
    VIVI_BACKEND_CANVAS_FAILURE_INVALID_SDK_RESULT = 7,
    VIVI_BACKEND_CANVAS_FAILURE_STALE = 8,
    VIVI_BACKEND_CANVAS_FAILURE_SHUTDOWN = 9,
} vivi_backend_canvas_operation_failure_t;

enum vivi_backend_canvas_declaration_flags {
    VIVI_BACKEND_CANVAS_DECLARATION_INPUT_SCHEMA_PRESENT = 1u << 0,
};

enum vivi_backend_canvas_action_flags {
    VIVI_BACKEND_CANVAS_ACTION_INPUT_SCHEMA_PRESENT = 1u << 0,
};

enum vivi_backend_canvas_instance_flags {
    VIVI_BACKEND_CANVAS_INSTANCE_OPEN_INPUT_PRESENT = 1u << 0,
    VIVI_BACKEND_CANVAS_INSTANCE_RENDERER_GENERATION_PRESENT = 1u << 1,
    VIVI_BACKEND_CANVAS_INSTANCE_TITLE_PRESENT = 1u << 2,
    VIVI_BACKEND_CANVAS_INSTANCE_URL_PRESENT = 1u << 3,
    VIVI_BACKEND_CANVAS_INSTANCE_STATUS_PRESENT = 1u << 4,
    VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_TITLE_PRESENT = 1u << 5,
    VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_INPUT_PRESENT = 1u << 6,
};

enum vivi_backend_canvas_snapshot_flags {
    VIVI_BACKEND_CANVAS_SNAPSHOT_SHUTDOWN_REQUESTED = 1u << 0,
};

enum vivi_backend_canvas_completion_flags {
    VIVI_BACKEND_CANVAS_COMPLETION_TITLE_PRESENT = 1u << 0,
    VIVI_BACKEND_CANVAS_COMPLETION_URL_PRESENT = 1u << 1,
    VIVI_BACKEND_CANVAS_COMPLETION_STATUS_PRESENT = 1u << 2,
    VIVI_BACKEND_CANVAS_COMPLETION_ACTION_RESULT_PRESENT = 1u << 3,
};

typedef struct vivi_backend_canvas_action {
    vivi_backend_span_t name;
    vivi_backend_span_t description;
    vivi_backend_span_t input_schema_json;
    uint32_t flags;
    uint32_t reserved;
} vivi_backend_canvas_action_t;

typedef struct vivi_backend_canvas_declaration {
    vivi_backend_span_t extension_id;
    vivi_backend_span_t extension_name;
    vivi_backend_span_t canvas_id;
    vivi_backend_span_t display_name;
    vivi_backend_span_t description;
    vivi_backend_span_t input_schema_json;
    uint32_t action_offset;
    uint32_t action_count;
    uint32_t flags;
    uint32_t reserved;
} vivi_backend_canvas_declaration_t;

typedef struct vivi_backend_canvas_instance {
    vivi_backend_canvas_key_t key;
    vivi_backend_span_t open_input_json;
    vivi_backend_span_t title;
    vivi_backend_span_t url;
    vivi_backend_span_t status;
    vivi_backend_span_t recorded_title;
    vivi_backend_span_t recorded_input_json;
    uint64_t renderer_generation;
    vivi_backend_canvas_runtime_t runtime;
    vivi_backend_canvas_record_t record;
    vivi_backend_canvas_degradation_t degradation;
    uint32_t flags;
    uint32_t reserved[2];
} vivi_backend_canvas_instance_t;

typedef struct vivi_backend_canvas_snapshot {
    vivi_backend_canvas_capability_t capability;
    vivi_backend_canvas_degradation_t registry_degradation;
    vivi_backend_canvas_degradation_t operation_degradation;
    uint32_t flags;
    uint32_t declaration_count;
    uint32_t action_count;
    uint32_t instance_count;
    uint32_t reserved;
} vivi_backend_canvas_snapshot_t;

typedef struct vivi_backend_canvas_completion {
    uint64_t operation_id;
    vivi_backend_canvas_operation_kind_t kind;
    vivi_backend_canvas_operation_outcome_t outcome;
    vivi_backend_canvas_operation_failure_t failure;
    uint32_t flags;
    vivi_backend_span_t title;
    vivi_backend_span_t url;
    vivi_backend_span_t status;
    vivi_backend_span_t action_result_json;
    uint32_t reserved[2];
} vivi_backend_canvas_completion_t;

typedef struct vivi_backend_canvas_operation {
    uint32_t abi_version;
    uint32_t struct_size;
    vivi_backend_canvas_operation_kind_t kind;
    uint32_t reserved0;
    vivi_backend_canvas_key_t key;
    vivi_backend_span_t action_name;
    vivi_backend_span_t open_input_json;
    vivi_backend_span_t action_input_json;
    /* Required for close/action; must be zero for open. */
    uint64_t expected_renderer_generation;
} vivi_backend_canvas_operation_t;

typedef struct vivi_backend_event {
    vivi_backend_event_kind_t kind;
    vivi_backend_content_kind_t content_kind;
    uint32_t byte_count;
    uint32_t model_count;
    uint32_t semantic_span_count;
    uint32_t session_count;
    uint32_t transcript_item_count;
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
    vivi_backend_session_scope_t session_scope;
    vivi_backend_session_resume_outcome_t session_resume_outcome;
    uint8_t default_saved;
    uint8_t cleanup_failed;
    uint8_t skipped_invalid_shards;
    uint8_t session_reserved;
    uint16_t reserved;
    vivi_backend_canvas_snapshot_t canvas_snapshot;
    vivi_backend_canvas_completion_t canvas_completion;
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
vivi_backend_result_t vivi_backend_refresh_sessions(
    vivi_backend_conversation_t *conversation,
    vivi_backend_session_request_t request);
vivi_backend_result_t vivi_backend_resume_session(
    vivi_backend_conversation_t *conversation,
    vivi_backend_resume_key_t key);
/*
 * Every span is relative to input_bytes. Inputs are immutable, spans may
 * overlap, and unreferenced bytes are ignored. {0, 0} is the only absent span.
 * On success all referenced bytes have been copied and out_operation_id is
 * nonzero. On failure out_operation_id is zero.
 */
vivi_backend_result_t vivi_backend_perform_canvas(
    vivi_backend_conversation_t *conversation,
    const vivi_backend_canvas_operation_t *operation,
    const uint8_t *input_bytes,
    uint32_t input_byte_count,
    uint64_t *out_operation_id);
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
 * next_event always fills out_event for a pending event. If any caller-owned
 * buffer is too small it returns BUFFER_TOO_SMALL without writing any buffer
 * or consuming the event; count fields report all required capacities.
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
    uint32_t semantic_span_capacity,
    vivi_backend_session_summary_t *sessions,
    uint32_t session_capacity,
    vivi_backend_transcript_item_t *transcript_items,
    uint32_t transcript_item_capacity,
    vivi_backend_canvas_declaration_t *canvas_declarations,
    uint32_t canvas_declaration_capacity,
    vivi_backend_canvas_action_t *canvas_actions,
    uint32_t canvas_action_capacity,
    vivi_backend_canvas_instance_t *canvas_instances,
    uint32_t canvas_instance_capacity);
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
