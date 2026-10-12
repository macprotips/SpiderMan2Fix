/* A stand-in for the translation layer's d3d12.dll (D3DMetal, vkd3d...). Implements just
 * enough of ID3D12Device / ID3D12GraphicsCommandList for the shim to hook, and records
 * every ResourceBarrier so the test can check what the shim injected. */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include "../../shim/sm2fix_dxbc.h"
#include "../../shim/sm2fix_core.h"

static UINT g_last_sampler_filter, g_last_rootsig_filter;
static int g_last_rootsig_checksum_ok;

void mock_get_sampler_info(UINT *heap_filter, UINT *rootsig_filter, int *checksum_ok)
{
    *heap_filter = g_last_sampler_filter;
    *rootsig_filter = g_last_rootsig_filter;
    *checksum_ok = g_last_rootsig_checksum_ok;
}

static int g_d3dmetal_like;
static LONG g_uav_barriers, g_other_barriers, g_dispatches, g_signals, g_executes, g_indirect;

void mock_get_queue_counts(LONG *signals, LONG *executes, LONG *indirect)
{
    *signals = g_signals;
    *executes = g_executes;
    *indirect = g_indirect;
}

void mock_get_counts(LONG *uav, LONG *other, LONG *dispatches)
{
    *uav = g_uav_barriers;
    *other = g_other_barriers;
    *dispatches = g_dispatches;
}

/* ---- generic refcounted object used for PSOs */
struct object { IUnknownVtbl *vtbl; LONG refs; };

static HRESULT STDMETHODCALLTYPE obj_QI(IUnknown *iface, REFIID riid, void **out) { *out = iface; return S_OK; }
static ULONG STDMETHODCALLTYPE obj_AddRef(IUnknown *iface) { return InterlockedIncrement(&((struct object *)iface)->refs); }
static ULONG STDMETHODCALLTYPE obj_Release(IUnknown *iface)
{
    struct object *o = (struct object *)iface;
    ULONG r = InterlockedDecrement(&o->refs);
    if (!r) HeapFree(GetProcessHeap(), 0, o);
    return r;
}
static IUnknownVtbl obj_vtbl = {obj_QI, obj_AddRef, obj_Release};

static void *new_object(void)
{
    struct object *o = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*o));
    o->vtbl = &obj_vtbl;
    o->refs = 1;
    return o;
}

/* ---- command list */
struct list { ID3D12GraphicsCommandListVtbl *vtbl; LONG refs; };

static HRESULT STDMETHODCALLTYPE list_QI(ID3D12GraphicsCommandList *iface, REFIID riid, void **out)
{
    if (IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList) || IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList1)
            || IsEqualGUID(riid, &IID_IUnknown))
    {
        iface->lpVtbl->AddRef(iface);
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE list_AddRef(ID3D12GraphicsCommandList *iface) { return InterlockedIncrement(&((struct list *)iface)->refs); }
static ULONG STDMETHODCALLTYPE list_Release(ID3D12GraphicsCommandList *iface)
{
    struct list *l = (struct list *)iface;
    ULONG r = InterlockedDecrement(&l->refs);
    if (!r) HeapFree(GetProcessHeap(), 0, l);
    return r;
}
static HRESULT STDMETHODCALLTYPE list_Reset(ID3D12GraphicsCommandList *iface, ID3D12CommandAllocator *a, ID3D12PipelineState *p) { return S_OK; }
static void STDMETHODCALLTYPE list_ClearState(ID3D12GraphicsCommandList *iface, ID3D12PipelineState *p) {}
static void STDMETHODCALLTYPE list_SetPipelineState(ID3D12GraphicsCommandList *iface, ID3D12PipelineState *p) {}
static void STDMETHODCALLTYPE list_Dispatch(ID3D12GraphicsCommandList *iface, UINT x, UINT y, UINT z) { InterlockedIncrement(&g_dispatches); }
static void STDMETHODCALLTYPE list_ResourceBarrier(ID3D12GraphicsCommandList *iface, UINT n, const D3D12_RESOURCE_BARRIER *b)
{
    UINT i;
    for (i = 0; i < n; i++)
    {
        if (b[i].Type == D3D12_RESOURCE_BARRIER_TYPE_UAV && !b[i].UAV.pResource)
            InterlockedIncrement(&g_uav_barriers);
        else
            InterlockedIncrement(&g_other_barriers);
    }
}

static void STDMETHODCALLTYPE list_ExecuteIndirect(ID3D12GraphicsCommandList *iface, ID3D12CommandSignature *sig,
        UINT max, ID3D12Resource *args, UINT64 off, ID3D12Resource *cnt, UINT64 cnt_off)
{
    InterlockedIncrement(&g_indirect);
}

/* readback buffer: timestamps 1000, 1600, 2600 ticks at 1 MHz -> deltas 600 us, 1000 us */
static UINT64 g_readback[131072] = {1000, 1600, 2600};   /* 1 MiB */
struct resource { ID3D12ResourceVtbl *vtbl; LONG refs; };
static HRESULT STDMETHODCALLTYPE res_QI(ID3D12Resource *iface, REFIID riid, void **out) { *out = iface; return S_OK; }
static ULONG STDMETHODCALLTYPE res_AddRef(ID3D12Resource *iface) { return InterlockedIncrement(&((struct resource *)iface)->refs); }
static ULONG STDMETHODCALLTYPE res_Release(ID3D12Resource *iface) { return InterlockedDecrement(&((struct resource *)iface)->refs); }
static HRESULT STDMETHODCALLTYPE res_Map(ID3D12Resource *iface, UINT sub, const D3D12_RANGE *range, void **out) { *out = g_readback; return S_OK; }
static void STDMETHODCALLTYPE res_Unmap(ID3D12Resource *iface, UINT sub, const D3D12_RANGE *range) {}
static D3D12_RESOURCE_DESC *STDMETHODCALLTYPE res_GetDesc(ID3D12Resource *iface, D3D12_RESOURCE_DESC *ret)
{
    memset(ret, 0, sizeof(*ret));
    ret->Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    ret->Width = sizeof(g_readback);
    return ret;
}
static D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE res_GetGPUVirtualAddress(ID3D12Resource *iface) { return 0xabc000; }
static HRESULT STDMETHODCALLTYPE res_GetHeapProperties(ID3D12Resource *iface, D3D12_HEAP_PROPERTIES *p, D3D12_HEAP_FLAGS *f)
{
    memset(p, 0, sizeof(*p));
    p->Type = D3D12_HEAP_TYPE_UPLOAD;
    if (f)
        *f = D3D12_HEAP_FLAG_NONE;
    return S_OK;
}
static ID3D12ResourceVtbl res_vtbl;
static struct resource g_resource = {&res_vtbl, 1};

/* a READBACK-heap buffer: 4 KiB, a quarter of it non-zero */
static UINT64 g_rb_data[512] = {1, 2, 3, 4};
static HRESULT STDMETHODCALLTYPE rb_Map(ID3D12Resource *iface, UINT sub, const D3D12_RANGE *range, void **out) { *out = g_rb_data; return S_OK; }
static D3D12_RESOURCE_DESC *STDMETHODCALLTYPE rb_GetDesc(ID3D12Resource *iface, D3D12_RESOURCE_DESC *ret)
{
    memset(ret, 0, sizeof(*ret));
    ret->Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    ret->Width = sizeof(g_rb_data);
    return ret;
}
static HRESULT STDMETHODCALLTYPE rb_GetHeapProperties(ID3D12Resource *iface, D3D12_HEAP_PROPERTIES *p, D3D12_HEAP_FLAGS *f)
{
    memset(p, 0, sizeof(*p));
    p->Type = D3D12_HEAP_TYPE_READBACK;
    return S_OK;
}
static ID3D12ResourceVtbl rb_vtbl;
static struct resource g_rb_resource = {&rb_vtbl, 1};
void *mock_get_rb_resource(void) { return &g_rb_resource; }

/* ---- descriptor heaps: plain memory, 32-byte descriptors, GPU handles from 0x100000 */
struct dheap { ID3D12DescriptorHeapVtbl *vtbl; LONG refs; SIZE_T cpu; UINT64 gpu; };
static HRESULT STDMETHODCALLTYPE dheap_QI(ID3D12DescriptorHeap *iface, REFIID riid, void **out)
{
    iface->lpVtbl->AddRef(iface);
    *out = iface;
    return S_OK;
}
static ULONG STDMETHODCALLTYPE dheap_AddRef(ID3D12DescriptorHeap *iface) { return InterlockedIncrement(&((struct dheap *)iface)->refs); }
static ULONG STDMETHODCALLTYPE dheap_Release(ID3D12DescriptorHeap *iface) { return InterlockedDecrement(&((struct dheap *)iface)->refs); }
static D3D12_CPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE dheap_GetCPU(ID3D12DescriptorHeap *iface, D3D12_CPU_DESCRIPTOR_HANDLE *ret)
{
    ret->ptr = ((struct dheap *)iface)->cpu;
    return ret;
}
static D3D12_GPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE dheap_GetGPU(ID3D12DescriptorHeap *iface, D3D12_GPU_DESCRIPTOR_HANDLE *ret)
{
    ret->ptr = ((struct dheap *)iface)->gpu;
    return ret;
}
static ID3D12DescriptorHeapVtbl dheap_vtbl;
void *mock_get_readback_resource(void) { return &g_resource; }

static void STDMETHODCALLTYPE list_EndQuery(ID3D12GraphicsCommandList *iface, ID3D12QueryHeap *h, D3D12_QUERY_TYPE t, UINT i) {}
static void STDMETHODCALLTYPE list_ResolveQueryData(ID3D12GraphicsCommandList *iface, ID3D12QueryHeap *h, D3D12_QUERY_TYPE t,
        UINT start, UINT count, ID3D12Resource *dest, UINT64 off)
{
    if (g_d3dmetal_like && t == D3D12_QUERY_TYPE_TIMESTAMP)
        memset((uint8_t *)g_readback + off, 0, count * sizeof(UINT64));
}
/* Like D3DMetal on M1-M4 when g_d3dmetal_like is set: 60 Hz clock, resolves write zeros. */
void mock_set_d3dmetal_like(int on) { g_d3dmetal_like = on; }
static HRESULT STDMETHODCALLTYPE queue_GetClockCalibration(ID3D12CommandQueue *iface, UINT64 *gpu, UINT64 *cpu)
{
    *gpu = 0; /* D3DMetal-like: no usable GPU clock */
    *cpu = 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE queue_GetTimestampFrequency(ID3D12CommandQueue *iface, UINT64 *f)
{
    *f = g_d3dmetal_like ? 60 : 1000000;
    return S_OK;
}

static ID3D12GraphicsCommandListVtbl list_vtbl;
static void STDMETHODCALLTYPE list_CopyBufferRegion(ID3D12GraphicsCommandList *iface, ID3D12Resource *d, UINT64 doff,
        ID3D12Resource *s, UINT64 soff, UINT64 n) {}
static void STDMETHODCALLTYPE list_SetComputeRootDescriptorTable(ID3D12GraphicsCommandList *iface, UINT i,
        D3D12_GPU_DESCRIPTOR_HANDLE h) {}

/* ---- fence: completes asynchronously ~5 ms after a queue signals it, like a GPU */
struct fence { ID3D12FenceVtbl *vtbl; LONG refs; volatile LONG64 completed; UINT64 wait_value; HANDLE wait_event; };

static HRESULT STDMETHODCALLTYPE fence_QI(ID3D12Fence *iface, REFIID riid, void **out) { *out = iface; return S_OK; }
static ULONG STDMETHODCALLTYPE fence_AddRef(ID3D12Fence *iface) { return InterlockedIncrement(&((struct fence *)iface)->refs); }
static ULONG STDMETHODCALLTYPE fence_Release(ID3D12Fence *iface) { return InterlockedDecrement(&((struct fence *)iface)->refs); }
static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(ID3D12Fence *iface) { return ((struct fence *)iface)->completed; }
static HRESULT STDMETHODCALLTYPE fence_SetEventOnCompletion(ID3D12Fence *iface, UINT64 value, HANDLE event)
{
    struct fence *f = (struct fence *)iface;
    f->wait_value = value;
    f->wait_event = event;
    if ((UINT64)f->completed >= value)
        SetEvent(event);
    return S_OK;
}
static ID3D12FenceVtbl fence_vtbl;

struct pending { struct fence *fence; UINT64 value; };
static DWORD WINAPI complete_later(void *arg)
{
    struct pending *p = arg;
    Sleep(5);
    InterlockedExchange64(&p->fence->completed, p->value);
    if (p->fence->wait_event && p->fence->wait_value <= p->value)
        SetEvent(p->fence->wait_event);
    HeapFree(GetProcessHeap(), 0, p);
    return 0;
}

/* ---- queue */
struct queue { ID3D12CommandQueueVtbl *vtbl; LONG refs; };
static HRESULT STDMETHODCALLTYPE queue_QI(ID3D12CommandQueue *iface, REFIID riid, void **out) { *out = iface; return S_OK; }
static ULONG STDMETHODCALLTYPE queue_AddRef(ID3D12CommandQueue *iface) { return 2; }
static ULONG STDMETHODCALLTYPE queue_Release(ID3D12CommandQueue *iface) { return 1; }
static void STDMETHODCALLTYPE queue_ExecuteCommandLists(ID3D12CommandQueue *iface, UINT n, ID3D12CommandList *const *l)
{
    InterlockedIncrement(&g_executes);
}
static HRESULT STDMETHODCALLTYPE queue_Signal(ID3D12CommandQueue *iface, ID3D12Fence *fence, UINT64 value)
{
    struct pending *p = HeapAlloc(GetProcessHeap(), 0, sizeof(*p));
    InterlockedIncrement(&g_signals);
    p->fence = (struct fence *)fence;
    p->value = value;
    CloseHandle(CreateThread(NULL, 0, complete_later, p, 0, NULL));
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE queue_Wait(ID3D12CommandQueue *iface, ID3D12Fence *fence, UINT64 value) { return S_OK; }
static ID3D12CommandQueueVtbl queue_vtbl;

/* ---- device */
struct device { ID3D12Device4Vtbl *vtbl; LONG refs; };

static HRESULT STDMETHODCALLTYPE dev_QI(ID3D12Device4 *iface, REFIID riid, void **out)
{
    if (IsEqualGUID(riid, &IID_ID3D12Device) || IsEqualGUID(riid, &IID_ID3D12Device1)
            || IsEqualGUID(riid, &IID_ID3D12Device2) || IsEqualGUID(riid, &IID_ID3D12Device3)
            || IsEqualGUID(riid, &IID_ID3D12Device4) || IsEqualGUID(riid, &IID_IUnknown))
    {
        iface->lpVtbl->AddRef(iface);
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE dev_AddRef(ID3D12Device4 *iface) { return InterlockedIncrement(&((struct device *)iface)->refs); }
static ULONG STDMETHODCALLTYPE dev_Release(ID3D12Device4 *iface) { return InterlockedDecrement(&((struct device *)iface)->refs); }
static unsigned long long g_last_cs_hash;

/* Hash of the last compute shader the driver was given (to see replacements). */
unsigned long long mock_get_last_cs_hash(void)
{
    return g_last_cs_hash;
}

static HRESULT STDMETHODCALLTYPE dev_CreateComputePipelineState(ID3D12Device4 *iface,
        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **out)
{
    g_last_cs_hash = sm2_shader_hash(desc->CS.pShaderBytecode, desc->CS.BytecodeLength);
    *out = new_object();
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreatePipelineState(ID3D12Device4 *iface,
        const D3D12_PIPELINE_STATE_STREAM_DESC *desc, REFIID riid, void **out)
{
    const void *code;
    size_t size;

    if (sm2_stream_find_cs(desc->pPipelineStateSubobjectStream, desc->SizeInBytes, &code, &size) == SM2_STREAM_COMPUTE)
        g_last_cs_hash = sm2_shader_hash(code, size);
    *out = new_object();
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateDescriptorHeap(ID3D12Device4 *iface, const D3D12_DESCRIPTOR_HEAP_DESC *desc,
        REFIID riid, void **out)
{
    static UINT64 next_gpu = 0x100000;
    struct dheap *h = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*h));

    h->vtbl = &dheap_vtbl;
    h->refs = 1;
    h->cpu = (SIZE_T)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (SIZE_T)desc->NumDescriptors * 32 + 32);
    if (desc->Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)
    {
        h->gpu = next_gpu;
        next_gpu += (UINT64)desc->NumDescriptors * 32 + 0x1000;
    }
    *out = h;
    return S_OK;
}
static UINT STDMETHODCALLTYPE dev_GetDescriptorHandleIncrementSize(ID3D12Device4 *iface, D3D12_DESCRIPTOR_HEAP_TYPE t) { return 32; }
static D3D12_SHADER_RESOURCE_VIEW_DESC g_last_srv;

/* The last SRV description the driver was given (to see pool_fix's raw views). */
void mock_get_last_srv(D3D12_SHADER_RESOURCE_VIEW_DESC *out) { *out = g_last_srv; }

static void STDMETHODCALLTYPE dev_CreateShaderResourceView(ID3D12Device4 *iface, ID3D12Resource *r,
        const D3D12_SHADER_RESOURCE_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (d)
        g_last_srv = *d;
}
static D3D12_UNORDERED_ACCESS_VIEW_DESC g_last_uav;

/* The last UAV description the driver was given (to see the fix's raw UAVs). */
void mock_get_last_uav(D3D12_UNORDERED_ACCESS_VIEW_DESC *out) { *out = g_last_uav; }

static void STDMETHODCALLTYPE dev_CreateUnorderedAccessView(ID3D12Device4 *iface, ID3D12Resource *r, ID3D12Resource *counter,
        const D3D12_UNORDERED_ACCESS_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (d)
        g_last_uav = *d;
}
static void STDMETHODCALLTYPE dev_CopyDescriptorsSimple(ID3D12Device4 *iface, UINT n, D3D12_CPU_DESCRIPTOR_HANDLE d,
        D3D12_CPU_DESCRIPTOR_HANDLE s, D3D12_DESCRIPTOR_HEAP_TYPE t) {}
static HRESULT STDMETHODCALLTYPE dev_CreateCommandList(ID3D12Device4 *iface, UINT mask, D3D12_COMMAND_LIST_TYPE type,
        ID3D12CommandAllocator *alloc, ID3D12PipelineState *pso, REFIID riid, void **out)
{
    struct list *l = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*l));
    l->vtbl = &list_vtbl;
    l->refs = 1;
    *out = l;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateGraphicsPipelineState(ID3D12Device4 *iface,
        const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID riid, void **out)
{
    *out = NULL;
    return E_INVALIDARG; /* pretend the translation layer can't compile it */
}
static HRESULT STDMETHODCALLTYPE dev_CheckFeatureSupport(ID3D12Device4 *iface, D3D12_FEATURE f, void *data, UINT size)
{
    memset(data, 0xab, size);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateCommandSignature(ID3D12Device4 *iface, const D3D12_COMMAND_SIGNATURE_DESC *d,
        ID3D12RootSignature *rs, REFIID riid, void **out)
{
    *out = new_object();
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateRootSignature(ID3D12Device4 *iface, UINT mask, const void *blob, SIZE_T size,
        REFIID riid, void **out)
{
    unsigned int minmax, total;
    uint32_t first = 0;
    void *copy = HeapAlloc(GetProcessHeap(), 0, size);

    memcpy(copy, blob, size);
    g_last_rootsig_checksum_ok = sm2_dxbc_checksum_ok(copy, size);
    sm2_rootsig_scan_samplers(copy, size, SM2_MINMAX_KEEP, &minmax, &total, &first);
    memcpy(&g_last_rootsig_filter, (const uint8_t *)blob + 36 + 8 + 24, 4);
    HeapFree(GetProcessHeap(), 0, copy);
    *out = new_object();
    return S_OK;
}
static void STDMETHODCALLTYPE dev_CreateSampler(ID3D12Device4 *iface, const D3D12_SAMPLER_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE handle)
{
    g_last_sampler_filter = desc->Filter;
}
static HRESULT STDMETHODCALLTYPE dev_CreateQueryHeap(ID3D12Device4 *iface, const D3D12_QUERY_HEAP_DESC *desc,
        REFIID riid, void **out)
{
    *out = new_object();
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateCommandQueue(ID3D12Device4 *iface, const D3D12_COMMAND_QUEUE_DESC *desc,
        REFIID riid, void **out)
{
    struct queue *q = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*q));
    q->vtbl = &queue_vtbl;
    *out = q;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE dev_CreateFence(ID3D12Device4 *iface, UINT64 initial, D3D12_FENCE_FLAGS flags,
        REFIID riid, void **out)
{
    struct fence *f = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*f));
    f->vtbl = &fence_vtbl;
    f->refs = 1;
    f->completed = initial;
    *out = f;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE dev_CreateCommandList1(ID3D12Device4 *iface, UINT mask, D3D12_COMMAND_LIST_TYPE type,
        D3D12_COMMAND_LIST_FLAGS flags, REFIID riid, void **out)
{
    return dev_CreateCommandList(iface, mask, type, NULL, NULL, riid, out);
}

/* Vtables live in a read-only section on real drivers; keep ours const-ish via a
 * separate page we protect, so the shim's VirtualProtect path is exercised. */
static ID3D12Device4Vtbl *dev_vtbl;
static struct device g_device;

HRESULT WINAPI mock_D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **out)
{
    DWORD old;

    if (!dev_vtbl)
    {
        dev_vtbl = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        dev_vtbl->QueryInterface = dev_QI;
        dev_vtbl->AddRef = dev_AddRef;
        dev_vtbl->Release = dev_Release;
        dev_vtbl->CreateComputePipelineState = dev_CreateComputePipelineState;
        dev_vtbl->CreatePipelineState = dev_CreatePipelineState;
        dev_vtbl->CreateCommandList = dev_CreateCommandList;
        dev_vtbl->CreateCommandList1 = dev_CreateCommandList1;
        dev_vtbl->CreateGraphicsPipelineState = dev_CreateGraphicsPipelineState;
        dev_vtbl->CheckFeatureSupport = dev_CheckFeatureSupport;
        dev_vtbl->CreateCommandSignature = dev_CreateCommandSignature;
        dev_vtbl->CreateRootSignature = dev_CreateRootSignature;
        dev_vtbl->CreateCommandQueue = dev_CreateCommandQueue;
        dev_vtbl->CreateFence = dev_CreateFence;
        dev_vtbl->CreateSampler = dev_CreateSampler;
        dev_vtbl->CreateQueryHeap = dev_CreateQueryHeap;
        dev_vtbl->CreateDescriptorHeap = dev_CreateDescriptorHeap;
        dev_vtbl->GetDescriptorHandleIncrementSize = dev_GetDescriptorHandleIncrementSize;
        dev_vtbl->CreateShaderResourceView = dev_CreateShaderResourceView;
        dev_vtbl->CreateUnorderedAccessView = dev_CreateUnorderedAccessView;
        dev_vtbl->CopyDescriptorsSimple = dev_CopyDescriptorsSimple;
        VirtualProtect(dev_vtbl, 4096, PAGE_READONLY, &old);

        list_vtbl.QueryInterface = list_QI;
        list_vtbl.AddRef = list_AddRef;
        list_vtbl.Release = list_Release;
        list_vtbl.Reset = list_Reset;
        list_vtbl.ClearState = list_ClearState;
        list_vtbl.SetPipelineState = list_SetPipelineState;
        list_vtbl.Dispatch = list_Dispatch;
        list_vtbl.SetComputeRootDescriptorTable = list_SetComputeRootDescriptorTable;
        list_vtbl.CopyBufferRegion = list_CopyBufferRegion;
        list_vtbl.ResourceBarrier = list_ResourceBarrier;
        list_vtbl.ExecuteIndirect = list_ExecuteIndirect;
        list_vtbl.EndQuery = list_EndQuery;
        list_vtbl.ResolveQueryData = list_ResolveQueryData;
        res_vtbl.QueryInterface = res_QI;
        res_vtbl.AddRef = res_AddRef;
        res_vtbl.Release = res_Release;
        res_vtbl.Map = res_Map;
        res_vtbl.Unmap = res_Unmap;
        res_vtbl.GetDesc = res_GetDesc;
        res_vtbl.GetGPUVirtualAddress = res_GetGPUVirtualAddress;
        res_vtbl.GetHeapProperties = res_GetHeapProperties;
        rb_vtbl = res_vtbl;
        rb_vtbl.Map = rb_Map;
        rb_vtbl.GetDesc = rb_GetDesc;
        rb_vtbl.GetHeapProperties = rb_GetHeapProperties;
        dheap_vtbl.QueryInterface = dheap_QI;
        dheap_vtbl.AddRef = dheap_AddRef;
        dheap_vtbl.Release = dheap_Release;
        dheap_vtbl.GetCPUDescriptorHandleForHeapStart = dheap_GetCPU;
        dheap_vtbl.GetGPUDescriptorHandleForHeapStart = dheap_GetGPU;

        fence_vtbl.QueryInterface = fence_QI;
        fence_vtbl.AddRef = fence_AddRef;
        fence_vtbl.Release = fence_Release;
        fence_vtbl.GetCompletedValue = fence_GetCompletedValue;
        fence_vtbl.SetEventOnCompletion = fence_SetEventOnCompletion;

        queue_vtbl.QueryInterface = queue_QI;
        queue_vtbl.AddRef = queue_AddRef;
        queue_vtbl.Release = queue_Release;
        queue_vtbl.ExecuteCommandLists = queue_ExecuteCommandLists;
        queue_vtbl.Signal = queue_Signal;
        queue_vtbl.Wait = queue_Wait;
        queue_vtbl.GetTimestampFrequency = queue_GetTimestampFrequency;
        queue_vtbl.GetClockCalibration = queue_GetClockCalibration;
    }
    g_device.vtbl = dev_vtbl;
    g_device.refs = 1;
    if (out)
        *out = &g_device;
    return S_OK;
}
