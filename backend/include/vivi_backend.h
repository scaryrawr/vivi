#ifndef VIVI_BACKEND_H
#define VIVI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VIVI_BACKEND_ABI_VERSION 1
#define VIVI_BACKEND_LIFECYCLE_SCAFFOLD 0

typedef enum vivi_backend_result {
    VIVI_BACKEND_OK = 0,
    VIVI_BACKEND_INVALID_ARGUMENT = 1,
} vivi_backend_result_t;

typedef struct vivi_backend_status {
    uint32_t abi_version;
    uint32_t lifecycle;
} vivi_backend_status_t;

vivi_backend_result_t vivi_backend_status(vivi_backend_status_t *out_status);

#ifdef __cplusplus
}
#endif

#endif
