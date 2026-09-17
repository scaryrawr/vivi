#include "vivi_backend.h"

#include <assert.h>

int main(void) {
    vivi_backend_conversation_t *conversation = 0;
    vivi_backend_conversation_options_t options = {
        .working_directory = (const uint8_t *)"/tmp",
        .working_directory_length = 4,
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
    assert(vivi_backend_next_event(conversation, &event, 0, 0) != VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_close(conversation) == VIVI_BACKEND_OK);
    assert(vivi_backend_close(conversation) == VIVI_BACKEND_OK);
    vivi_backend_destroy(conversation);
    return 0;
}
