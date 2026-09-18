#ifndef VIVI_BACKEND_H
#define VIVI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VIVI_BACKEND_ABI_VERSION 11
#define VIVI_BACKEND_MAX_COMMAND_ARGUMENT_BYTES 65536u

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

typedef enum vivi_backend_attachment_media_type {
    VIVI_BACKEND_ATTACHMENT_PNG = 1,
    VIVI_BACKEND_ATTACHMENT_JPEG = 2,
    VIVI_BACKEND_ATTACHMENT_GIF = 3,
    VIVI_BACKEND_ATTACHMENT_WEBP = 4,
} vivi_backend_attachment_media_type_t;

typedef struct vivi_backend_submission_attachment {
    uint32_t struct_size;
    vivi_backend_attachment_media_type_t media_type;
    const uint8_t *identity;
    uint32_t identity_length;
    const uint8_t *display_name;
    uint32_t display_name_length;
    const uint8_t *bytes;
    uint32_t byte_length;
    uint32_t reserved;
} vivi_backend_submission_attachment_t;

typedef struct vivi_backend_submission {
    uint32_t struct_size;
    uint32_t reserved;
    const uint8_t *prompt;
    uint32_t prompt_length;
    const vivi_backend_submission_attachment_t *attachments;
    uint32_t attachment_count;
} vivi_backend_submission_t;

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
    const uint8_t *sessions_directory;
    uint32_t sessions_directory_length;
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
    VIVI_BACKEND_EVENT_SESSION_CATALOG = 17,
    VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE = 18,
    VIVI_BACKEND_EVENT_SESSION_TRACKING_FAILURE = 19,
    VIVI_BACKEND_EVENT_SESSION_RESUME = 20,
    VIVI_BACKEND_EVENT_USER_INPUT_REQUEST = 21,
    VIVI_BACKEND_EVENT_COMMAND_CATALOG = 22,
    VIVI_BACKEND_EVENT_COMMAND_CATALOG_FAILURE = 23,
    VIVI_BACKEND_EVENT_COMMAND_COMPLETED = 24,
    VIVI_BACKEND_EVENT_COMMAND_FAILED = 25,
} vivi_backend_event_kind_t;

typedef enum vivi_backend_content_kind {
    VIVI_BACKEND_CONTENT_NONE = 0,
    VIVI_BACKEND_CONTENT_TEXT = 1,
    VIVI_BACKEND_CONTENT_MODEL_CATALOG = 2,
    VIVI_BACKEND_CONTENT_MODEL_SWITCH = 3,
    VIVI_BACKEND_CONTENT_TOOL = 4,
    VIVI_BACKEND_CONTENT_SESSION_CATALOG = 5,
    VIVI_BACKEND_CONTENT_SESSION_RESUME = 6,
    VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST = 7,
    VIVI_BACKEND_CONTENT_COMMAND_CATALOG = 8,
    VIVI_BACKEND_CONTENT_COMMAND_EXECUTION = 9,
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

typedef struct vivi_backend_command_key {
    uint64_t generation;
    uint32_t slot;
    uint32_t reserved;
} vivi_backend_command_key_t;

typedef enum vivi_backend_command_source {
    VIVI_BACKEND_COMMAND_SOURCE_VIVI = 1,
    VIVI_BACKEND_COMMAND_SOURCE_SDK_BUILTIN = 2,
    VIVI_BACKEND_COMMAND_SOURCE_EXTENSION = 3,
} vivi_backend_command_source_t;

typedef enum vivi_backend_command_action {
    VIVI_BACKEND_COMMAND_ACTION_EXECUTE = 1,
    VIVI_BACKEND_COMMAND_ACTION_OPEN_MODEL_SELECTION = 2,
    VIVI_BACKEND_COMMAND_ACTION_OPEN_SESSION_HISTORY = 3,
} vivi_backend_command_action_t;

typedef enum vivi_backend_command_argument_policy {
    VIVI_BACKEND_COMMAND_ARGUMENT_NONE = 1,
    VIVI_BACKEND_COMMAND_ARGUMENT_OPTIONAL = 2,
    VIVI_BACKEND_COMMAND_ARGUMENT_REQUIRED = 3,
} vivi_backend_command_argument_policy_t;

typedef struct vivi_backend_command {
    uint32_t struct_size;
    vivi_backend_command_key_t key;
    vivi_backend_span_t name;
    vivi_backend_span_t display_name;
    vivi_backend_span_t description;
    vivi_backend_span_t hint;
    vivi_backend_command_source_t source;
    vivi_backend_command_action_t action;
    vivi_backend_command_argument_policy_t argument_policy;
    uint32_t reserved;
} vivi_backend_command_t;

typedef struct vivi_backend_command_execution {
    uint32_t struct_size;
    uint32_t reserved;
    vivi_backend_command_key_t key;
    const uint8_t *arguments;
    uint32_t argument_length;
    uint32_t reserved2;
} vivi_backend_command_execution_t;

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

typedef struct vivi_backend_user_input_choice {
    vivi_backend_span_t text;
    uint32_t reserved;
} vivi_backend_user_input_choice_t;

typedef enum vivi_backend_user_input_answer_kind {
    VIVI_BACKEND_USER_INPUT_ANSWER_NONE = 0,
    VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE = 1,
    VIVI_BACKEND_USER_INPUT_ANSWER_FREEFORM = 2,
} vivi_backend_user_input_answer_kind_t;

typedef struct vivi_backend_user_input_response {
    uint32_t struct_size;
    vivi_backend_user_input_answer_kind_t answer_kind;
    const uint8_t *request_id;
    uint32_t request_id_length;
    const uint8_t *answer;
    uint32_t answer_length;
    uint32_t reserved;
} vivi_backend_user_input_response_t;

typedef struct vivi_backend_event {
    vivi_backend_event_kind_t kind;
    vivi_backend_content_kind_t content_kind;
    uint32_t byte_count;
    uint32_t model_count;
    uint32_t semantic_span_count;
    uint32_t session_count;
    uint32_t transcript_item_count;
    uint32_t user_input_choice_count;
    uint32_t command_count;
    vivi_backend_span_t content;
    vivi_backend_span_t selected_model_id;
    vivi_backend_span_t tool_call_id;
    vivi_backend_span_t tool_title;
    vivi_backend_span_t tool_detail;
    vivi_backend_span_t tool_input;
    vivi_backend_span_t user_input_request_id;
    vivi_backend_span_t user_input_question;
    vivi_backend_command_key_t command_key;
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
    uint8_t allow_freeform;
    uint16_t reserved;
} vivi_backend_event_t;

/* Open and submit copy their input bytes before returning. */
vivi_backend_result_t vivi_backend_open(
    const vivi_backend_conversation_options_t *options,
    vivi_backend_conversation_t **out_conversation);
vivi_backend_result_t vivi_backend_submit(
    vivi_backend_conversation_t *conversation,
    const vivi_backend_submission_t *submission);
vivi_backend_result_t vivi_backend_refresh_commands(
    vivi_backend_conversation_t *conversation);
vivi_backend_result_t vivi_backend_execute_command(
    vivi_backend_conversation_t *conversation,
    const vivi_backend_command_execution_t *execution);
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
vivi_backend_result_t vivi_backend_respond_to_user_input(
    vivi_backend_conversation_t *conversation,
    const vivi_backend_user_input_response_t *response);
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
    vivi_backend_user_input_choice_t *user_input_choices,
    uint32_t user_input_choice_capacity,
    vivi_backend_command_t *commands,
    uint32_t command_capacity);
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
