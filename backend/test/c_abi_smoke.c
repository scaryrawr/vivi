#include "vivi_backend.h"

#include <assert.h>

int main(void) {
    vivi_backend_conversation_t *conversation = 0;
    vivi_backend_conversation_options_t options = {
        .working_directory = (const uint8_t *)"/tmp",
        .working_directory_length = 4,
        .settings_path = 0,
        .settings_path_length = 0,
        .copilot_cli_launch = VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT,
        .wake = 0,
        .wake_context = 0,
    };
    vivi_backend_event_t event = {0};

    assert(vivi_backend_open(0, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    options.copilot_cli_launch = (vivi_backend_copilot_cli_launch_t)99;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(conversation == 0);
    options.copilot_cli_launch = VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT;
    assert(vivi_backend_open(&options, &conversation) == VIVI_BACKEND_OK);
    assert(conversation != 0);
    assert(vivi_backend_submit(conversation, (const uint8_t *)"", 0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(VIVI_BACKEND_ABI_VERSION == 5);
    assert(VIVI_BACKEND_EVENT_CLOSED == 8);
    assert(VIVI_BACKEND_EVENT_MODEL_SWITCH == 14);
    assert(VIVI_BACKEND_EVENT_TOOL_STARTED == 15);
    assert(VIVI_BACKEND_EVENT_TOOL_FINISHED == 16);
    assert(VIVI_BACKEND_TOOL_RESULT_IMAGE == 4);
    assert(vivi_backend_refresh_models(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_switch_model(
               conversation,
               (const uint8_t *)"copilot/default",
               15,
               (vivi_backend_reasoning_effort_t)99) ==
           VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_next_event(conversation, &event, 0, 0, 0, 0) !=
           VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_close(conversation) == VIVI_BACKEND_OK);
    assert(vivi_backend_close(conversation) == VIVI_BACKEND_OK);
    vivi_backend_destroy(conversation);
    return 0;
}
