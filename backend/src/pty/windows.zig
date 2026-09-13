const std = @import("std");
const windows = std.os.windows;

const Endpoint = extern struct {
    values: [8]isize,
};

const Coord = extern struct {
    x: i16,
    y: i16,
};

const StartupInfoEx = extern struct {
    startup_info: windows.STARTUPINFOW,
    attribute_list: ?*anyopaque,
};

const JobBasicLimitInformation = extern struct {
    per_process_user_time_limit: windows.LARGE_INTEGER,
    per_job_user_time_limit: windows.LARGE_INTEGER,
    limit_flags: windows.DWORD,
    minimum_working_set_size: windows.SIZE_T,
    maximum_working_set_size: windows.SIZE_T,
    active_process_limit: windows.DWORD,
    affinity: windows.ULONG_PTR,
    priority_class: windows.DWORD,
    scheduling_class: windows.DWORD,
};

const IoCounters = extern struct {
    read_operation_count: u64,
    write_operation_count: u64,
    other_operation_count: u64,
    read_transfer_count: u64,
    write_transfer_count: u64,
    other_transfer_count: u64,
};

const JobExtendedLimitInformation = extern struct {
    basic_limit_information: JobBasicLimitInformation,
    io_info: IoCounters,
    process_memory_limit: windows.SIZE_T,
    job_memory_limit: windows.SIZE_T,
    peak_process_memory_used: windows.SIZE_T,
    peak_job_memory_used: windows.SIZE_T,
};

const pseudo_console_attribute: windows.ULONG_PTR = 0x00020016;
const extended_startup_info_present: windows.DWORD = 0x00080000;
const create_suspended: windows.DWORD = 0x00000004;
const create_unicode_environment: windows.DWORD = 0x00000400;
const job_object_limit_kill_on_close: windows.DWORD = 0x00002000;
const job_object_extended_limit_information: c_int = 9;
const wait_object_0: windows.DWORD = 0;
const infinite: windows.DWORD = 0xffffffff;
const error_broken_pipe: windows.DWORD = 109;
const error_operation_aborted: windows.DWORD = 995;

extern "kernel32" fn CreatePipe(
    read_pipe: *windows.HANDLE,
    write_pipe: *windows.HANDLE,
    attributes: *windows.SECURITY_ATTRIBUTES,
    size: windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreatePseudoConsole(
    size: Coord,
    input: windows.HANDLE,
    output: windows.HANDLE,
    flags: windows.DWORD,
    pseudo_console: *windows.HANDLE,
) callconv(.winapi) windows.HRESULT;
extern "kernel32" fn ClosePseudoConsole(
    pseudo_console: windows.HANDLE,
) callconv(.winapi) void;
extern "kernel32" fn CloseHandle(
    handle: windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(
    attribute_list: ?*anyopaque,
    attribute_count: windows.DWORD,
    flags: windows.DWORD,
    bytes: *windows.SIZE_T,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(
    attribute_list: *anyopaque,
    flags: windows.DWORD,
    attribute: windows.ULONG_PTR,
    value: *const anyopaque,
    size: windows.SIZE_T,
    previous_value: ?*anyopaque,
    return_size: ?*windows.SIZE_T,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(
    attribute_list: *anyopaque,
) callconv(.winapi) void;
extern "kernel32" fn CreateJobObjectW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    job: windows.HANDLE,
    information_class: c_int,
    information: *const anyopaque,
    information_length: windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateProcessW(
    application_name: ?windows.LPCWSTR,
    command_line: windows.LPWSTR,
    process_attributes: ?*windows.SECURITY_ATTRIBUTES,
    thread_attributes: ?*windows.SECURITY_ATTRIBUTES,
    inherit_handles: windows.BOOL,
    creation_flags: windows.DWORD,
    environment: ?*anyopaque,
    current_directory: windows.LPCWSTR,
    startup_info: *windows.STARTUPINFOW,
    process_information: *windows.PROCESS.INFORMATION,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(
    job: windows.HANDLE,
    process: windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(
    thread: windows.HANDLE,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn TerminateProcess(
    process: windows.HANDLE,
    exit_code: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: *anyopaque,
    length: windows.DWORD,
    amount: *windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: *const anyopaque,
    length: windows.DWORD,
    amount: *windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn TerminateJobObject(
    job: windows.HANDLE,
    exit_code: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetExitCodeProcess(
    process: windows.HANDLE,
    exit_code: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

fn handle(endpoint: *const Endpoint, index: usize) ?windows.HANDLE {
    const value = endpoint.values[index];
    return if (value == 0) null else @ptrFromInt(@as(usize, @bitCast(value)));
}

fn storeHandle(endpoint: *Endpoint, index: usize, value: windows.HANDLE) void {
    endpoint.values[index] = @bitCast(@intFromPtr(value));
}

fn closeOptional(value: *?windows.HANDLE) void {
    if (value.*) |present| _ = CloseHandle(present);
    value.* = null;
}

fn makeCommandLine(
    allocator: std.mem.Allocator,
    command: []const u16,
) ![:0]u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral(
        "bash.exe --noprofile --norc -i +m -c \"",
    );
    const capacity = prefix.len + command.len * 2 + 2;
    const line = try allocator.allocSentinel(u16, capacity, 0);
    var output: usize = 0;
    @memcpy(line[output..][0..prefix.len], prefix);
    output += prefix.len;
    var index: usize = 0;
    while (index < command.len) {
        var slashes: usize = 0;
        while (index < command.len and command[index] == '\\') : (index += 1)
            slashes += 1;
        if (index == command.len) {
            @memset(line[output..][0 .. slashes * 2], '\\');
            output += slashes * 2;
            break;
        }
        if (command[index] == '"') {
            @memset(line[output..][0 .. slashes * 2 + 1], '\\');
            output += slashes * 2 + 1;
        } else {
            @memset(line[output..][0..slashes], '\\');
            output += slashes;
        }
        line[output] = command[index];
        output += 1;
        index += 1;
    }
    line[output] = '"';
    output += 1;
    line[output] = 0;
    return line[0..output :0];
}

fn spawn(
    cwd_utf8: []const u8,
    command_utf8: []const u8,
    rows: u16,
    columns: u16,
    endpoint: *Endpoint,
) !void {
    const allocator = std.heap.page_allocator;
    const cwd = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd_utf8);
    defer allocator.free(cwd);
    const command = try std.unicode.utf8ToUtf16LeAllocZ(
        allocator,
        command_utf8,
    );
    defer allocator.free(command);
    const command_line = try makeCommandLine(allocator, command);
    defer allocator.free(command_line);

    var input_read: ?windows.HANDLE = null;
    defer closeOptional(&input_read);
    var input_write: ?windows.HANDLE = null;
    defer closeOptional(&input_write);
    var output_read: ?windows.HANDLE = null;
    defer closeOptional(&output_read);
    var output_write: ?windows.HANDLE = null;
    defer closeOptional(&output_write);
    var pseudo_console: ?windows.HANDLE = null;
    defer if (pseudo_console) |value| ClosePseudoConsole(value);
    var job: ?windows.HANDLE = null;
    defer closeOptional(&job);
    var process: windows.PROCESS.INFORMATION = undefined;
    var process_created = false;
    defer if (process_created) {
        _ = TerminateProcess(process.hProcess, 125);
        _ = CloseHandle(process.hThread);
        _ = CloseHandle(process.hProcess);
    };

    var security = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = windows.FALSE,
    };
    if (CreatePipe(
        &input_read.?,
        &input_write.?,
        &security,
        0,
    ) == windows.FALSE) return error.CreatePipeFailed;
    if (CreatePipe(
        &output_read.?,
        &output_write.?,
        &security,
        0,
    ) == windows.FALSE) return error.CreatePipeFailed;
    if (CreatePseudoConsole(
        .{ .x = @intCast(columns), .y = @intCast(rows) },
        input_read.?,
        output_write.?,
        0,
        &pseudo_console.?,
    ) < 0) return error.CreatePseudoConsoleFailed;
    closeOptional(&input_read);
    closeOptional(&output_write);

    var attribute_bytes: windows.SIZE_T = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
    const attribute_storage = try allocator.alignedAlloc(
        u8,
        .of(usize),
        attribute_bytes,
    );
    defer allocator.free(attribute_storage);
    const attribute_list: *anyopaque = @ptrCast(attribute_storage.ptr);
    if (InitializeProcThreadAttributeList(
        attribute_list,
        1,
        0,
        &attribute_bytes,
    ) == windows.FALSE) return error.AttributeListFailed;
    defer DeleteProcThreadAttributeList(attribute_list);
    if (UpdateProcThreadAttribute(
        attribute_list,
        0,
        pseudo_console_attribute,
        @ptrCast(&pseudo_console.?),
        @sizeOf(windows.HANDLE),
        null,
        null,
    ) == windows.FALSE) return error.AttributeUpdateFailed;

    var startup: StartupInfoEx = std.mem.zeroes(StartupInfoEx);
    startup.startup_info.cb = @sizeOf(StartupInfoEx);
    startup.attribute_list = attribute_list;
    job = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
    var limits: JobExtendedLimitInformation =
        std.mem.zeroes(JobExtendedLimitInformation);
    limits.basic_limit_information.limit_flags =
        job_object_limit_kill_on_close;
    if (SetInformationJobObject(
        job.?,
        job_object_extended_limit_information,
        &limits,
        @sizeOf(JobExtendedLimitInformation),
    ) == windows.FALSE) return error.JobConfigurationFailed;
    if (CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        windows.FALSE,
        extended_startup_info_present |
            create_suspended |
            create_unicode_environment,
        null,
        cwd.ptr,
        &startup.startup_info,
        &process,
    ) == windows.FALSE) return error.CreateProcessFailed;
    process_created = true;
    if (AssignProcessToJobObject(
        job.?,
        process.hProcess,
    ) == windows.FALSE) return error.AssignJobFailed;
    if (ResumeThread(process.hThread) == 0xffffffff)
        return error.ResumeThreadFailed;
    _ = CloseHandle(process.hThread);

    endpoint.* = std.mem.zeroes(Endpoint);
    storeHandle(endpoint, 0, output_read.?);
    output_read = null;
    storeHandle(endpoint, 1, input_write.?);
    input_write = null;
    storeHandle(endpoint, 2, process.hProcess);
    storeHandle(endpoint, 3, job.?);
    job = null;
    storeHandle(endpoint, 4, pseudo_console.?);
    pseudo_console = null;
    process_created = false;
}

export fn vivi_pty_spawn(
    cwd: [*:0]const u8,
    command: [*:0]const u8,
    rows: u16,
    columns: u16,
    endpoint: *Endpoint,
) c_int {
    spawn(
        std.mem.span(cwd),
        std.mem.span(command),
        rows,
        columns,
        endpoint,
    ) catch return -1;
    return 0;
}

export fn vivi_pty_read(
    endpoint: *Endpoint,
    buffer: [*]u8,
    length: usize,
) isize {
    const output = handle(endpoint, 0) orelse return -1;
    var amount: windows.DWORD = 0;
    if (ReadFile(
        output,
        buffer,
        @intCast(@min(length, std.math.maxInt(windows.DWORD))),
        &amount,
        null,
    ) == windows.FALSE) {
        const code = GetLastError();
        if (code == error_broken_pipe or code == error_operation_aborted)
            return 0;
        return -1;
    }
    return amount;
}

export fn vivi_pty_write_all(
    endpoint: *Endpoint,
    buffer: [*]const u8,
    length: usize,
) c_int {
    const input = handle(endpoint, 1) orelse return -1;
    var written: usize = 0;
    while (written < length) {
        var amount: windows.DWORD = 0;
        if (WriteFile(
            input,
            buffer + written,
            @intCast(@min(
                length - written,
                std.math.maxInt(windows.DWORD),
            )),
            &amount,
            null,
        ) == windows.FALSE or amount == 0) return -1;
        written += amount;
    }
    return 0;
}

export fn vivi_pty_terminate(
    endpoint: *Endpoint,
    grace_ms: u32,
) c_int {
    _ = grace_ms;
    const process = handle(endpoint, 2);
    if (process) |value| {
        if (WaitForSingleObject(value, 0) == wait_object_0) return 0;
    }
    if (handle(endpoint, 3)) |job| {
        if (TerminateJobObject(job, 1) != windows.FALSE) return 0;
    }
    if (process) |value| {
        if (TerminateProcess(value, 1) != windows.FALSE) return 0;
        if (WaitForSingleObject(value, 0) == wait_object_0) return 0;
    }
    return -1;
}

export fn vivi_pty_wait(
    endpoint: *Endpoint,
    kind: *c_int,
    value: *u32,
) c_int {
    const process = handle(endpoint, 2) orelse return -1;
    if (WaitForSingleObject(process, infinite) != wait_object_0) return -1;
    var exit_code: windows.DWORD = 0;
    if (GetExitCodeProcess(process, &exit_code) == windows.FALSE) return -1;
    if (handle(endpoint, 3)) |job| _ = TerminateJobObject(job, exit_code);
    if (handle(endpoint, 4)) |pseudo_console| {
        ClosePseudoConsole(pseudo_console);
        endpoint.values[4] = 0;
    }
    kind.* = 1;
    value.* = exit_code;
    return 0;
}

export fn vivi_pty_close(endpoint: *Endpoint) void {
    for (0..4) |index| {
        if (handle(endpoint, index)) |value| _ = CloseHandle(value);
        endpoint.values[index] = 0;
    }
    if (handle(endpoint, 4)) |pseudo_console|
        ClosePseudoConsole(pseudo_console);
    endpoint.values[4] = 0;
}
