#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "native.h"

typedef void *HANDLE;
typedef HANDLE HPCON;
typedef int BOOL;
typedef long HRESULT;
typedef unsigned char BYTE;
typedef short SHORT;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef uintptr_t ULONG_PTR;
typedef unsigned long long ULONGLONG;
typedef wchar_t WCHAR;
typedef WCHAR *LPWSTR;
typedef const WCHAR *LPCWSTR;
typedef void *LPVOID;
typedef const void *LPCVOID;
typedef size_t SIZE_T;

typedef struct {
    short X;
    short Y;
} COORD;

typedef union {
    struct {
        DWORD LowPart;
        long HighPart;
    };
    long long QuadPart;
} LARGE_INTEGER;

typedef struct {
    DWORD nLength;
    LPVOID lpSecurityDescriptor;
    BOOL bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct {
    DWORD cb;
    LPWSTR lpReserved;
    LPWSTR lpDesktop;
    LPWSTR lpTitle;
    DWORD dwX;
    DWORD dwY;
    DWORD dwXSize;
    DWORD dwYSize;
    DWORD dwXCountChars;
    DWORD dwYCountChars;
    DWORD dwFillAttribute;
    DWORD dwFlags;
    WORD wShowWindow;
    WORD cbReserved2;
    BYTE *lpReserved2;
    HANDLE hStdInput;
    HANDLE hStdOutput;
    HANDLE hStdError;
} STARTUPINFOW;

typedef struct _PROC_THREAD_ATTRIBUTE_LIST PROC_THREAD_ATTRIBUTE_LIST;
typedef PROC_THREAD_ATTRIBUTE_LIST *PPROC_THREAD_ATTRIBUTE_LIST;

typedef struct {
    STARTUPINFOW StartupInfo;
    PPROC_THREAD_ATTRIBUTE_LIST lpAttributeList;
} STARTUPINFOEXW;

typedef struct {
    HANDLE hProcess;
    HANDLE hThread;
    DWORD dwProcessId;
    DWORD dwThreadId;
} PROCESS_INFORMATION;

typedef struct {
    LARGE_INTEGER PerProcessUserTimeLimit;
    LARGE_INTEGER PerJobUserTimeLimit;
    DWORD LimitFlags;
    SIZE_T MinimumWorkingSetSize;
    SIZE_T MaximumWorkingSetSize;
    DWORD ActiveProcessLimit;
    ULONG_PTR Affinity;
    DWORD PriorityClass;
    DWORD SchedulingClass;
} JOBOBJECT_BASIC_LIMIT_INFORMATION;

typedef struct {
    ULONGLONG ReadOperationCount;
    ULONGLONG WriteOperationCount;
    ULONGLONG OtherOperationCount;
    ULONGLONG ReadTransferCount;
    ULONGLONG WriteTransferCount;
    ULONGLONG OtherTransferCount;
} IO_COUNTERS;

typedef struct {
    JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    IO_COUNTERS IoInfo;
    SIZE_T ProcessMemoryLimit;
    SIZE_T JobMemoryLimit;
    SIZE_T PeakProcessMemoryUsed;
    SIZE_T PeakJobMemoryUsed;
} JOBOBJECT_EXTENDED_LIMIT_INFORMATION;

#define WINAPI __attribute__((stdcall))
#define DLLIMPORT __declspec(dllimport)
#define FALSE 0
#define CP_UTF8 65001
#define MB_ERR_INVALID_CHARS 8
#define HEAP_ZERO_MEMORY 8
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE ((DWORD_PTR)0x00020016)
#define EXTENDED_STARTUPINFO_PRESENT 0x00080000
#define CREATE_SUSPENDED 0x00000004
#define CREATE_UNICODE_ENVIRONMENT 0x00000400
#define JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE 0x00002000
#define JobObjectExtendedLimitInformation 9
#define WAIT_OBJECT_0 0
#define INFINITE 0xffffffff
#define ERROR_BROKEN_PIPE 109
#define ERROR_OPERATION_ABORTED 995
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define FAILED(value) ((HRESULT)(value) < 0)

typedef ULONG_PTR DWORD_PTR;

DLLIMPORT int WINAPI MultiByteToWideChar(
    unsigned int, DWORD, const char *, int, WCHAR *, int
);
DLLIMPORT HANDLE WINAPI GetProcessHeap(void);
DLLIMPORT LPVOID WINAPI HeapAlloc(HANDLE, DWORD, SIZE_T);
DLLIMPORT BOOL WINAPI HeapFree(HANDLE, DWORD, LPVOID);
DLLIMPORT BOOL WINAPI CreatePipe(
    HANDLE *, HANDLE *, SECURITY_ATTRIBUTES *, DWORD
);
DLLIMPORT HRESULT WINAPI CreatePseudoConsole(
    COORD, HANDLE, HANDLE, DWORD, HPCON *
);
DLLIMPORT void WINAPI ClosePseudoConsole(HPCON);
DLLIMPORT BOOL WINAPI CloseHandle(HANDLE);
DLLIMPORT BOOL WINAPI InitializeProcThreadAttributeList(
    PPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD, SIZE_T *
);
DLLIMPORT BOOL WINAPI UpdateProcThreadAttribute(
    PPROC_THREAD_ATTRIBUTE_LIST,
    DWORD,
    DWORD_PTR,
    LPVOID,
    SIZE_T,
    LPVOID,
    SIZE_T *
);
DLLIMPORT void WINAPI DeleteProcThreadAttributeList(
    PPROC_THREAD_ATTRIBUTE_LIST
);
DLLIMPORT HANDLE WINAPI CreateJobObjectW(LPVOID, LPCWSTR);
DLLIMPORT BOOL WINAPI SetInformationJobObject(
    HANDLE, int, LPVOID, DWORD
);
DLLIMPORT BOOL WINAPI CreateProcessW(
    LPCWSTR,
    LPWSTR,
    LPVOID,
    LPVOID,
    BOOL,
    DWORD,
    LPVOID,
    LPCWSTR,
    STARTUPINFOW *,
    PROCESS_INFORMATION *
);
DLLIMPORT BOOL WINAPI AssignProcessToJobObject(HANDLE, HANDLE);
DLLIMPORT DWORD WINAPI ResumeThread(HANDLE);
DLLIMPORT BOOL WINAPI TerminateProcess(HANDLE, unsigned int);
DLLIMPORT BOOL WINAPI ReadFile(HANDLE, LPVOID, DWORD, DWORD *, LPVOID);
DLLIMPORT BOOL WINAPI WriteFile(HANDLE, LPCVOID, DWORD, DWORD *, LPVOID);
DLLIMPORT DWORD WINAPI GetLastError(void);
DLLIMPORT DWORD WINAPI WaitForSingleObject(HANDLE, DWORD);
DLLIMPORT BOOL WINAPI TerminateJobObject(HANDLE, unsigned int);
DLLIMPORT BOOL WINAPI GetExitCodeProcess(HANDLE, DWORD *);

static void zero_bytes(void *destination, size_t length) {
    unsigned char *bytes = (unsigned char *)destination;
    while (length-- != 0) *bytes++ = 0;
}

static void copy_bytes(void *destination, const void *source, size_t length) {
    unsigned char *output = (unsigned char *)destination;
    const unsigned char *input = (const unsigned char *)source;
    while (length-- != 0) *output++ = *input++;
}

static size_t wide_length(const wchar_t *text) {
    size_t length = 0;
    while (text[length] != L'\0') ++length;
    return length;
}

static HANDLE value_handle(const vivi_pty_endpoint_t *endpoint, int index) {
    return (HANDLE)(uintptr_t)endpoint->values[index];
}

static wchar_t *utf8_to_wide(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (count == 0) return NULL;
    wchar_t *wide = (wchar_t *)HeapAlloc(
        GetProcessHeap(),
        0,
        (SIZE_T)count * sizeof(wchar_t)
    );
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count) == 0) {
        HeapFree(GetProcessHeap(), 0, wide);
        return NULL;
    }
    return wide;
}

static wchar_t *make_command_line(const wchar_t *command) {
    const wchar_t prefix[] = L"bash.exe --noprofile --norc -i +m -c \"";
    size_t prefix_len = (sizeof(prefix) / sizeof(prefix[0])) - 1;
    size_t command_len = wide_length(command);
    size_t capacity = prefix_len + command_len * 2 + 3;
    wchar_t *line = (wchar_t *)HeapAlloc(
        GetProcessHeap(),
        HEAP_ZERO_MEMORY,
        capacity * sizeof(wchar_t)
    );
    if (line == NULL) return NULL;
    copy_bytes(line, prefix, prefix_len * sizeof(wchar_t));
    size_t out = prefix_len;
    size_t index = 0;
    while (index < command_len) {
        size_t slashes = 0;
        while (index < command_len && command[index] == L'\\') {
            ++slashes;
            ++index;
        }
        if (index == command_len) {
            for (size_t count = 0; count < slashes * 2; ++count) {
                line[out++] = L'\\';
            }
            break;
        }
        if (command[index] == L'"') {
            for (size_t count = 0; count < slashes * 2 + 1; ++count) {
                line[out++] = L'\\';
            }
            line[out++] = L'"';
            ++index;
            continue;
        }
        for (size_t count = 0; count < slashes; ++count) line[out++] = L'\\';
        line[out++] = command[index++];
    }
    line[out++] = L'"';
    line[out] = L'\0';
    return line;
}

int vivi_pty_spawn(
    const char *cwd,
    const char *command,
    uint16_t rows,
    uint16_t columns,
    vivi_pty_endpoint_t *endpoint
) {
    HANDLE input_read = NULL;
    HANDLE input_write = NULL;
    HANDLE output_read = NULL;
    HANDLE output_write = NULL;
    HANDLE job = NULL;
    HPCON pseudo_console = NULL;
    PPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    wchar_t *wide_cwd = NULL;
    wchar_t *wide_command = NULL;
    wchar_t *command_line = NULL;
    PROCESS_INFORMATION process;
    STARTUPINFOEXW startup;
    SIZE_T attribute_bytes = 0;
    SECURITY_ATTRIBUTES security = { sizeof(security), NULL, FALSE };
    zero_bytes(endpoint, sizeof(*endpoint));
    zero_bytes(&process, sizeof(process));
    zero_bytes(&startup, sizeof(startup));
    startup.StartupInfo.cb = sizeof(startup);

    if (!CreatePipe(&input_read, &input_write, &security, 0)) goto failed;
    if (!CreatePipe(&output_read, &output_write, &security, 0)) goto failed;
    COORD size = { (SHORT)columns, (SHORT)rows };
    if (FAILED(CreatePseudoConsole(size, input_read, output_write, 0, &pseudo_console))) {
        goto failed;
    }
    CloseHandle(input_read);
    input_read = NULL;
    CloseHandle(output_write);
    output_write = NULL;

    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
    attributes = (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
        GetProcessHeap(),
        0,
        attribute_bytes
    );
    if (attributes == NULL) goto failed;
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes)) {
        goto failed;
    }
    if (!UpdateProcThreadAttribute(
        attributes,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        sizeof(pseudo_console),
        NULL,
        NULL
    )) goto failed;
    startup.lpAttributeList = attributes;

    wide_cwd = utf8_to_wide(cwd);
    wide_command = utf8_to_wide(command);
    if (wide_cwd == NULL || wide_command == NULL) goto failed;
    command_line = make_command_line(wide_command);
    if (command_line == NULL) goto failed;

    job = CreateJobObjectW(NULL, NULL);
    if (job == NULL) goto failed;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    zero_bytes(&limits, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &limits,
        sizeof(limits)
    )) goto failed;

    if (!CreateProcessW(
        NULL,
        command_line,
        NULL,
        NULL,
        FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
        NULL,
        wide_cwd,
        &startup.StartupInfo,
        &process
    )) goto failed;
    if (!AssignProcessToJobObject(job, process.hProcess)) goto failed;
    if (ResumeThread(process.hThread) == (DWORD)-1) goto failed;
    CloseHandle(process.hThread);
    process.hThread = NULL;

    endpoint->values[0] = (intptr_t)(uintptr_t)output_read;
    endpoint->values[1] = (intptr_t)(uintptr_t)input_write;
    endpoint->values[2] = (intptr_t)(uintptr_t)process.hProcess;
    endpoint->values[3] = (intptr_t)(uintptr_t)job;
    endpoint->values[4] = (intptr_t)(uintptr_t)pseudo_console;

    DeleteProcThreadAttributeList(attributes);
    HeapFree(GetProcessHeap(), 0, attributes);
    HeapFree(GetProcessHeap(), 0, wide_cwd);
    HeapFree(GetProcessHeap(), 0, wide_command);
    HeapFree(GetProcessHeap(), 0, command_line);
    return 0;

failed:
    if (process.hProcess != NULL) TerminateProcess(process.hProcess, 125);
    if (process.hThread != NULL) CloseHandle(process.hThread);
    if (process.hProcess != NULL) CloseHandle(process.hProcess);
    if (job != NULL) CloseHandle(job);
    if (pseudo_console != NULL) ClosePseudoConsole(pseudo_console);
    if (input_read != NULL) CloseHandle(input_read);
    if (input_write != NULL) CloseHandle(input_write);
    if (output_read != NULL) CloseHandle(output_read);
    if (output_write != NULL) CloseHandle(output_write);
    if (attributes != NULL) {
        DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);
    }
    if (wide_cwd != NULL) HeapFree(GetProcessHeap(), 0, wide_cwd);
    if (wide_command != NULL) HeapFree(GetProcessHeap(), 0, wide_command);
    if (command_line != NULL) HeapFree(GetProcessHeap(), 0, command_line);
    return -1;
}

intptr_t vivi_pty_read(
    vivi_pty_endpoint_t *endpoint,
    void *buffer,
    size_t length
) {
    DWORD amount = 0;
    if (!ReadFile(
        value_handle(endpoint, 0),
        buffer,
        (DWORD)length,
        &amount,
        NULL
    )) {
        DWORD error = GetLastError();
        if (error == ERROR_BROKEN_PIPE || error == ERROR_OPERATION_ABORTED) return 0;
        return -1;
    }
    return (intptr_t)amount;
}

int vivi_pty_write_all(
    vivi_pty_endpoint_t *endpoint,
    const void *buffer,
    size_t length
) {
    const unsigned char *cursor = (const unsigned char *)buffer;
    while (length != 0) {
        DWORD amount = 0;
        DWORD chunk = length > UINT32_MAX ? UINT32_MAX : (DWORD)length;
        if (!WriteFile(value_handle(endpoint, 1), cursor, chunk, &amount, NULL)) {
            return -1;
        }
        if (amount == 0) return -1;
        cursor += amount;
        length -= amount;
    }
    return 0;
}

int vivi_pty_terminate(vivi_pty_endpoint_t *endpoint, uint32_t grace_ms) {
    (void)grace_ms;
    HANDLE process = value_handle(endpoint, 2);
    if (process != NULL && WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
        return 0;
    }
    HANDLE job = value_handle(endpoint, 3);
    if (job != NULL && TerminateJobObject(job, 1)) return 0;
    if (process != NULL && TerminateProcess(process, 1)) return 0;
    return process != NULL && WaitForSingleObject(process, 0) == WAIT_OBJECT_0
        ? 0
        : -1;
}

int vivi_pty_wait(
    vivi_pty_endpoint_t *endpoint,
    int *kind,
    uint32_t *value
) {
    HANDLE process = value_handle(endpoint, 2);
    if (process == NULL || WaitForSingleObject(process, INFINITE) != WAIT_OBJECT_0) {
        return -1;
    }
    DWORD code = 0;
    if (!GetExitCodeProcess(process, &code)) return -1;
    HANDLE job = value_handle(endpoint, 3);
    if (job != NULL) (void)TerminateJobObject(job, code);
    HPCON pseudo_console = (HPCON)(uintptr_t)endpoint->values[4];
    if (pseudo_console != NULL) {
        ClosePseudoConsole(pseudo_console);
        endpoint->values[4] = 0;
    }
    *kind = VIVI_PTY_EXIT_CODE;
    *value = code;
    return 0;
}

void vivi_pty_close(vivi_pty_endpoint_t *endpoint) {
    for (int index = 0; index < 4; ++index) {
        HANDLE handle = value_handle(endpoint, index);
        if (handle != NULL && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
        endpoint->values[index] = 0;
    }
    HPCON pseudo_console = (HPCON)(uintptr_t)endpoint->values[4];
    if (pseudo_console != NULL) ClosePseudoConsole(pseudo_console);
    endpoint->values[4] = 0;
}
