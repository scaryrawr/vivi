#include "vivi_backend.h"

#include <assert.h>

int main(void) {
    vivi_backend_conversation_t *conversation = 0;
    vivi_backend_conversation_options_t options = {
        .abi_version = VIVI_BACKEND_ABI_VERSION,
        .struct_size = sizeof(vivi_backend_conversation_options_t),
        .working_directory = (const uint8_t *)"/tmp",
        .working_directory_length = 4,
        .settings_path = 0,
        .settings_path_length = 0,
        .copilot_cli_path = 0,
        .copilot_cli_path_length = 0,
        .copilot_cli_launch = VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT,
        .wake = 0,
        .wake_context = 0,
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
    assert(conversation == 0);
    assert(VIVI_BACKEND_ABI_VERSION == 8);
    assert(VIVI_BACKEND_PRESENTATION_SOURCE == 3);
    assert(VIVI_BACKEND_LANGUAGE_PYTHON == 15);
    assert(VIVI_BACKEND_TOKEN_META == 11);
    assert(VIVI_BACKEND_EVENT_CLOSED == 8);
    assert(VIVI_BACKEND_EVENT_MODEL_SWITCH == 14);
    assert(VIVI_BACKEND_EVENT_TOOL_STARTED == 15);
    assert(VIVI_BACKEND_EVENT_TOOL_FINISHED == 16);
    assert(VIVI_BACKEND_EVENT_SESSION_CATALOG == 17);
    assert(VIVI_BACKEND_EVENT_SESSION_RESUME == 19);
    assert(VIVI_BACKEND_TOOL_RESULT_IMAGE == 4);
    vivi_backend_resume_key_t key = {
        .generation = 1,
        .slot = 0,
        .reserved = 0,
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
    assert(vivi_backend_refresh_sessions(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_resume_session(0, key) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_close(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    vivi_backend_destroy(0);
    return 0;
}
