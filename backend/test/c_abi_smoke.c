#include "vivi_backend.h"

#include <assert.h>

int main(void) {
    vivi_backend_conversation_t *conversation = 0;
    vivi_backend_conversation_options_t options = {
        .abi_version = VIVI_BACKEND_ABI_VERSION,
        .struct_size = sizeof(vivi_backend_conversation_options_t),
        .working_directory = (const uint8_t *)"/tmp",
        .working_directory_length = 4,
        .settings_path = (const uint8_t *)"/tmp/settings.json",
        .settings_path_length = 18,
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
    assert(VIVI_BACKEND_ABI_VERSION == 7);
    assert(VIVI_BACKEND_EVENT_CLOSED == 8);
    assert(VIVI_BACKEND_EVENT_MODEL_SWITCH == 14);
    assert(VIVI_BACKEND_EVENT_TOOL_STARTED == 15);
    assert(VIVI_BACKEND_EVENT_TOOL_FINISHED == 16);
    assert(VIVI_BACKEND_TOOL_RESULT_IMAGE == 4);
    assert(vivi_backend_refresh_models(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_close(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    vivi_backend_destroy(0);
    return 0;
}
