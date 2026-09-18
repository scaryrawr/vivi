#include "vivi_backend.h"

#include <assert.h>
#include <stddef.h>

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
    assert(VIVI_BACKEND_ABI_VERSION == 11);
    assert(VIVI_BACKEND_SESSION_TITLE_MAX_CHARACTERS == 80);
    assert(VIVI_BACKEND_ATTACHMENT_MAX_COUNT == 32);
    assert(VIVI_BACKEND_ATTACHMENT_MAX_BYTES == 20 * 1024 * 1024);
    assert(VIVI_BACKEND_ATTACHMENT_IDENTITY_MAX_BYTES == 256);
    assert(VIVI_BACKEND_ATTACHMENT_DISPLAY_NAME_MAX_BYTES == 1024);
    assert(VIVI_BACKEND_MAX_COMMAND_ARGUMENT_BYTES == 65536u);
    assert(VIVI_BACKEND_ATTACHMENT_PNG == 1);
    assert(VIVI_BACKEND_PRESENTATION_SOURCE == 3);
    assert(VIVI_BACKEND_LANGUAGE_PYTHON == 15);
    assert(VIVI_BACKEND_TOKEN_META == 11);
    assert(VIVI_BACKEND_EVENT_CLOSED == 8);
    assert(VIVI_BACKEND_EVENT_MODEL_SWITCH == 14);
    assert(VIVI_BACKEND_EVENT_TOOL_STARTED == 15);
    assert(VIVI_BACKEND_EVENT_TOOL_FINISHED == 16);
    assert(VIVI_BACKEND_EVENT_SESSION_CATALOG == 17);
    assert(VIVI_BACKEND_EVENT_SESSION_RESUME == 19);
    assert(VIVI_BACKEND_EVENT_USER_INPUT_REQUEST == 20);
    assert(VIVI_BACKEND_EVENT_COMMAND_CATALOG == 21);
    assert(VIVI_BACKEND_EVENT_COMMAND_CATALOG_FAILURE == 22);
    assert(VIVI_BACKEND_EVENT_COMMAND_COMPLETED == 23);
    assert(VIVI_BACKEND_EVENT_COMMAND_FAILED == 24);
    assert(VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST == 7);
    assert(VIVI_BACKEND_CONTENT_COMMAND_CATALOG == 8);
    assert(VIVI_BACKEND_CONTENT_COMMAND_EXECUTION == 9);
    assert(VIVI_BACKEND_COMMAND_SOURCE_VIVI == 1);
    assert(VIVI_BACKEND_COMMAND_SOURCE_SDK_BUILTIN == 2);
    assert(VIVI_BACKEND_COMMAND_SOURCE_EXTENSION == 3);
    assert(VIVI_BACKEND_COMMAND_ACTION_EXECUTE == 1);
    assert(VIVI_BACKEND_COMMAND_ACTION_OPEN_MODEL_SELECTION == 2);
    assert(VIVI_BACKEND_COMMAND_ACTION_OPEN_SESSION_HISTORY == 3);
    assert(VIVI_BACKEND_COMMAND_ARGUMENT_NONE == 1);
    assert(VIVI_BACKEND_COMMAND_ARGUMENT_OPTIONAL == 2);
    assert(VIVI_BACKEND_COMMAND_ARGUMENT_REQUIRED == 3);
    assert(offsetof(vivi_backend_event_t, content)
        == offsetof(vivi_backend_event_t, user_input_choice_count)
            + sizeof(((vivi_backend_event_t *)0)->user_input_choice_count));
    assert(offsetof(vivi_backend_event_t, tool_input_presentation)
        == offsetof(vivi_backend_event_t, user_input_question)
            + sizeof(((vivi_backend_event_t *)0)->user_input_question));
    assert(offsetof(vivi_backend_event_t, command_count)
        > offsetof(vivi_backend_event_t, reserved));
    assert(offsetof(vivi_backend_event_t, command_key)
        > offsetof(vivi_backend_event_t, command_count));
    assert(VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE == 1);
    assert(VIVI_BACKEND_USER_INPUT_ANSWER_FREEFORM == 2);
    assert(VIVI_BACKEND_TOOL_RESULT_IMAGE == 4);
    vivi_backend_user_input_response_t response = {
        .struct_size = sizeof(vivi_backend_user_input_response_t),
        .answer_kind = VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE,
        .request_id = (const uint8_t *)"user-input-1",
        .request_id_length = 12,
        .answer = (const uint8_t *)"Yes",
        .answer_length = 3,
        .reserved = 0,
    };
    const uint8_t png[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    vivi_backend_submission_attachment_t attachment = {
        .struct_size = sizeof(vivi_backend_submission_attachment_t),
        .media_type = VIVI_BACKEND_ATTACHMENT_PNG,
        .identity = (const uint8_t *)"image-1",
        .identity_length = 7,
        .display_name = (const uint8_t *)"image.png",
        .display_name_length = 9,
        .bytes = png,
        .byte_length = sizeof(png),
        .reserved = 0,
    };
    vivi_backend_submission_t submission = {
        .struct_size = sizeof(vivi_backend_submission_t),
        .reserved = 0,
        .prompt = 0,
        .prompt_length = 0,
        .attachments = &attachment,
        .attachment_count = 1,
    };
    vivi_backend_resume_key_t key = {
        .generation = 1,
        .slot = 0,
        .reserved = 0,
    };
    vivi_backend_session_summary_t session = {
        .key = key,
        .flags = VIVI_BACKEND_SESSION_CURRENT,
    };
    vivi_backend_command_execution_t execution = {
        .struct_size = sizeof(vivi_backend_command_execution_t),
        .reserved = 0,
        .key = {.generation = 1, .slot = 2, .reserved = 0},
        .arguments = (const uint8_t *)"value",
        .argument_length = 5,
        .reserved2 = 0,
    };
    vivi_backend_command_t command = {
        .struct_size = sizeof(vivi_backend_command_t),
        .key = execution.key,
        .source = VIVI_BACKEND_COMMAND_SOURCE_SDK_BUILTIN,
        .action = VIVI_BACKEND_COMMAND_ACTION_EXECUTE,
        .argument_policy = VIVI_BACKEND_COMMAND_ARGUMENT_REQUIRED,
        .reserved = 0,
    };
    assert(command.key.generation == 1);
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
    assert(vivi_backend_refresh_commands(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_execute_command(0, &execution)
        == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_execute_command(0, 0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_submit(0, &submission) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_refresh_sessions(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_resume_session(0, key) == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_respond_to_user_input(0, &response)
        == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_respond_to_user_input(0, 0)
        == VIVI_BACKEND_INVALID_ARGUMENT);
    assert(vivi_backend_close(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    vivi_backend_destroy(0);
    return 0;
}
