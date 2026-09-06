#include "vivi_backend.h"

#include <assert.h>

int main(void) {
    vivi_backend_status_t status = {0};

    assert(vivi_backend_status(&status) == VIVI_BACKEND_OK);
    assert(status.abi_version == VIVI_BACKEND_ABI_VERSION);
    assert(status.lifecycle == VIVI_BACKEND_LIFECYCLE_SCAFFOLD);
    assert(vivi_backend_status(0) == VIVI_BACKEND_INVALID_ARGUMENT);
    return 0;
}
