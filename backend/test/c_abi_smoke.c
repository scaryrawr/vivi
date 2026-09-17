#include "vivi_backend.h"

#include <assert.h>
#include <stddef.h>

_Static_assert(sizeof(vivi_backend_canvas_key_t) == 24, "canvas key layout");
_Static_assert(_Alignof(vivi_backend_canvas_key_t) == _Alignof(uint32_t),
               "canvas key alignment");
_Static_assert(sizeof(vivi_backend_canvas_action_t) == 32,
               "canvas action layout");
_Static_assert(_Alignof(vivi_backend_canvas_action_t) ==
                   _Alignof(vivi_backend_span_t),
               "canvas action alignment");
_Static_assert(sizeof(vivi_backend_canvas_declaration_t) == 64,
               "canvas declaration layout");
_Static_assert(_Alignof(vivi_backend_canvas_declaration_t) ==
                   _Alignof(vivi_backend_span_t),
               "canvas declaration alignment");
_Static_assert(sizeof(vivi_backend_canvas_instance_t) == 104,
               "canvas instance layout");
_Static_assert(_Alignof(vivi_backend_canvas_instance_t) == _Alignof(uint64_t),
               "canvas instance alignment");
_Static_assert(sizeof(vivi_backend_canvas_snapshot_t) == 32,
               "canvas snapshot layout");
_Static_assert(_Alignof(vivi_backend_canvas_snapshot_t) == _Alignof(uint32_t),
               "canvas snapshot alignment");
_Static_assert(sizeof(vivi_backend_canvas_completion_t) == 64,
               "canvas completion layout");
_Static_assert(_Alignof(vivi_backend_canvas_completion_t) == _Alignof(uint64_t),
               "canvas completion alignment");
_Static_assert(sizeof(vivi_backend_canvas_operation_t) == 72,
               "canvas operation layout");
_Static_assert(_Alignof(vivi_backend_canvas_operation_t) ==
                   _Alignof(vivi_backend_span_t),
               "canvas operation alignment");
_Static_assert(offsetof(vivi_backend_canvas_operation_t, key) == 16,
               "canvas operation key offset");
_Static_assert(offsetof(vivi_backend_canvas_declaration_t, action_offset) == 48,
               "canvas action range offset");

int main(void) {
    vivi_backend_conversation_t *conversation = 0;
    vivi_backend_conversation_options_t options = {
        .abi_version = VIVI_BACKEND_ABI_VERSION,
        .struct_size = sizeof(vivi_backend_conversation_options_t),
        .working_directory = (const uint8_t *)"/tmp",
        .working_directory_length = 4,
        .settings_path = 0,
        .settings_path_length = 0,
        .sessions_directory = 0,
        .sessions_directory_length = 0,
        .copilot_cli_path = 0,
        .copilot_cli_path_length = 0,
        .copilot_cli_launch = VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT,
        .wake = 0,
        .wake_context = 0,
        .canvas_mode = VIVI_BACKEND_CANVAS_DISABLED,
        .canvas_options_reserved = 0,
    };

    assert(vivi_backend_open(0, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.abi_version = 0;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.abi_version = VIVI_BACKEND_ABI_VERSION;
    options.struct_size = 8;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.struct_size = sizeof(vivi_backend_conversation_options_t);
    options.copilot_cli_launch = (vivi_backend_copilot_cli_launch_t)99;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.copilot_cli_launch = VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT;
    options.canvas_mode = (vivi_backend_canvas_mode_t)99;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.canvas_mode = VIVI_BACKEND_CANVAS_DISABLED;
    options.canvas_options_reserved = 1;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.canvas_options_reserved = 0;
    assert(conversation == 0);
    assert(VIVI_BACKEND_ABI_VERSION == 9);
    assert(VIVI_BACKEND_PRESENTATION_SOURCE == 3);
    assert(VIVI_BACKEND_LANGUAGE_PYTHON == 15);
    assert(VIVI_BACKEND_TOKEN_META == 11);
    assert(VIVI_BACKEND_EVENT_CLOSED == 8);
    assert(VIVI_BACKEND_EVENT_MODEL_SWITCH == 14);
    assert(VIVI_BACKEND_EVENT_TOOL_STARTED == 15);
    assert(VIVI_BACKEND_EVENT_TOOL_FINISHED == 16);
    assert(VIVI_BACKEND_EVENT_SESSION_CATALOG == 17);
    assert(VIVI_BACKEND_EVENT_SESSION_RESUME == 20);
    assert(VIVI_BACKEND_EVENT_CANVAS_SNAPSHOT == 21);
    assert(VIVI_BACKEND_EVENT_CANVAS_OPERATION == 22);
    assert(VIVI_BACKEND_TOOL_RESULT_IMAGE == 4);
    vivi_backend_resume_key_t key = {
        .generation = 1,
        .slot = 0,
        .scope = VIVI_BACKEND_SESSION_SCOPE_LOCAL,
    };
    vivi_backend_session_summary_t session = {
        .key = key,
        .flags = VIVI_BACKEND_SESSION_CURRENT,
    };
    assert(session.key.generation == 1);
    vivi_backend_presentation_t presentation = {0};
    assert(vivi_backend_present_code_fragment(
               (const uint8_t *)"unknown", 7,
               (const uint8_t *)"text", 4,
               &presentation, 0, 0, 0, 0)
        == VIVI_BACKEND_BUFFER_TOO_SMALL);
    assert(presentation.kind == VIVI_BACKEND_PRESENTATION_LITERAL);
    assert(presentation.content.length == 4);
    assert(vivi_backend_refresh_models(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_refresh_sessions(0, VIVI_BACKEND_SESSION_REQUEST_LOCAL)
        == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_resume_session(0, key) == VIVI_BACKEND_INVALID_ARGUMENT);
    vivi_backend_canvas_operation_t operation = {
        .abi_version = VIVI_BACKEND_ABI_VERSION,
        .struct_size = sizeof(vivi_backend_canvas_operation_t),
        .kind = VIVI_BACKEND_CANVAS_OPERATION_CLOSE,
    };
    uint64_t operation_id = 1;
    assert(vivi_backend_perform_canvas(
               0, &operation, 0, 0, &operation_id)
        == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(operation_id == 0);
    vivi_backend_result_t (*perform_canvas)(
        vivi_backend_conversation_t *,
        const vivi_backend_canvas_operation_t *,
        const uint8_t *,
        uint32_t,
        uint64_t *) = vivi_backend_perform_canvas;
    vivi_backend_result_t (*next_event)(
        vivi_backend_conversation_t *,
        vivi_backend_event_t *,
        uint8_t *,
        uint32_t,
        vivi_backend_model_t *,
        uint32_t,
        vivi_backend_semantic_span_t *,
        uint32_t,
        vivi_backend_session_summary_t *,
        uint32_t,
        vivi_backend_transcript_item_t *,
        uint32_t,
        vivi_backend_canvas_declaration_t *,
        uint32_t,
        vivi_backend_canvas_action_t *,
        uint32_t,
        vivi_backend_canvas_instance_t *,
        uint32_t) = vivi_backend_next_event;
    assert(perform_canvas != 0);
    assert(next_event != 0);
    assert(vivi_backend_close(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    vivi_backend_destroy(0);
    return 0;
}
