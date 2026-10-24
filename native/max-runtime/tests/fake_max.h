/* Test-only ABI double. It never compiles, imports, or simulates a real MAX
 * graph. The real-SDK hosted fixture is a separate verification stage.
 */
#ifndef QUENDERIN_FAKE_MAX_H
#define QUENDERIN_FAKE_MAX_H
#include <stddef.h>
#include <stdint.h>
typedef struct Handle M_Status;
typedef struct Handle M_RuntimeConfig;
typedef struct Handle M_RuntimeContext;
typedef struct Handle M_Device;
typedef struct Handle M_CompileConfig;
typedef struct Handle M_AsyncCompiledModel;
typedef struct Handle M_WeightsRegistry;
typedef struct Handle M_AsyncModel;
typedef struct Handle M_TensorSpec;
typedef struct Handle M_AsyncTensorMap;
typedef struct Handle M_AsyncTensor;
typedef enum { M_FLOAT32 = 81, M_INT32 = 133 } M_Dtype;
typedef enum { M_HOST = 0, M_ACCELERATOR = 1 } M_DeviceType;
M_Status *M_newStatus(void);
int M_isError(const M_Status *);
const char *M_getError(const M_Status *);
const char *M_version(void);
void M_freeStatus(M_Status *);
M_RuntimeConfig *M_newRuntimeConfig(void);
void M_runtimeConfigAddDevice(M_RuntimeConfig *, M_Device *);
void M_freeRuntimeConfig(M_RuntimeConfig *);
M_RuntimeContext *M_newRuntimeContext(const M_RuntimeConfig *, M_Status *);
void M_freeRuntimeContext(M_RuntimeContext *);
M_Device *M_newDevice(M_DeviceType, int, M_Status *);
int M_isHostDevice(const M_Device *);
void M_freeDevice(M_Device *);
M_CompileConfig *M_newCompileConfig(void);
void M_setModelPath(M_CompileConfig *, const char *);
M_AsyncCompiledModel *M_compileModelSync(const M_RuntimeContext *, M_CompileConfig **, M_Status *);
void M_freeCompileConfig(M_CompileConfig *);
void M_freeCompiledModel(M_AsyncCompiledModel *);
M_WeightsRegistry *M_newWeightsRegistry(const char **, const void **, size_t, M_Status *);
void M_freeWeightsRegistry(M_WeightsRegistry *);
M_AsyncModel *M_initModel(const M_RuntimeContext *, const M_AsyncCompiledModel *, const M_WeightsRegistry *, M_Status *);
void M_waitForModel(M_AsyncModel *, M_Status *);
void M_freeModel(M_AsyncModel *);
M_TensorSpec *M_newTensorSpec(const int64_t *, int64_t, M_Dtype, const char *, const M_Device *);
void M_freeTensorSpec(M_TensorSpec *);
M_AsyncTensorMap *M_newAsyncTensorMap(const M_RuntimeContext *);
void M_borrowTensorInto(M_AsyncTensorMap *, void *, const M_TensorSpec *, M_Status *);
M_AsyncTensorMap *M_executeModelSync(const M_RuntimeContext *, M_AsyncModel *, M_AsyncTensorMap *, M_Status *);
M_AsyncTensor *M_getTensorByNameFrom(M_AsyncTensorMap *, const char *, M_Status *);
M_TensorSpec *M_getTensorSpec(const M_AsyncTensor *);
M_Device *M_getTensorDevice(const M_AsyncTensor *);
M_Dtype M_getTensorType(const M_AsyncTensor *);
size_t M_getTensorNumElements(const M_AsyncTensor *);
int M_isDynamicRanked(const M_TensorSpec *);
int64_t M_getRank(const M_TensorSpec *);
int64_t M_getDimAt(const M_TensorSpec *, size_t);
const void *M_getTensorData(const M_AsyncTensor *);
void M_freeTensor(M_AsyncTensor *);
void M_freeAsyncTensorMap(M_AsyncTensorMap *);
#endif
