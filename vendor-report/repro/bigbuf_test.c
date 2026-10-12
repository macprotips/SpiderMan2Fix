/* Checks reads from a 2 GB buffer at large element indices, through typed (R32_UINT,
 * R32G32B32A32_UINT), structured and raw views -- the way the game reads its vertex and
 * skinning pools (typed views of ~2 GB buffers, up to 536 million elements).
 *
 * Metal implements typed buffer views as "texture buffers", which have a maximum width.
 * If D3DMetal on M1-M4 can't address elements past such a limit, meshes stored high in
 * the game's pools would read zeros or garbage -- while every small-buffer test passes.
 *
 *   bigbuf_test.exe report.txt */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bigbuf_shaders.h"

#define BUF_SIZE (2147483648ull - 65536)       /* just under 2 GB, like the game's pools */
#define NPROBES 64

static FILE *report;
static ID3D12Device *device;
static ID3D12CommandQueue *queue;

static void out(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    if (report)
    {
        va_start(ap, fmt);
        vfprintf(report, fmt, ap);
        va_end(ap);
        fflush(report);
    }
}

static ID3D12Resource *make_buffer(D3D12_HEAP_TYPE heap, UINT64 size, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES hp = { heap };
    D3D12_RESOURCE_DESC rd = {0};
    ID3D12Resource *res = NULL;
    HRESULT hr;

    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = size;
    rd.Height = rd.DepthOrArraySize = rd.MipLevels = 1;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    rd.Flags = flags;
    if (FAILED(hr = ID3D12Device_CreateCommittedResource(device, &hp, D3D12_HEAP_FLAG_NONE, &rd, state, NULL,
            &IID_ID3D12Resource, (void **)&res)))
    {
        out("FAILED to create a %llu-byte buffer, hr=%#lx\n", (unsigned long long)size, (unsigned long)hr);
        return NULL;
    }
    return res;
}

static uint32_t expect(uint32_t idx)
{
    return (idx * 2654435761u) ^ 0x5bd1e995u;
}

int main(int argc, char **argv)
{
    HRESULT (WINAPI *create_device)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    HRESULT (WINAPI *serialize)(const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
    static const char *const view_names[4] = { "typed R32_UINT", "typed R32G32B32A32_UINT", "structured", "raw" };
    D3D12_DESCRIPTOR_RANGE ranges[2] = {
        { D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 5, 0, 0, 0 },
        { D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 1, 0, 0, 5 },
    };
    D3D12_ROOT_PARAMETER params[3] = {{0}};
    D3D12_ROOT_SIGNATURE_DESC rsd = {0};
    D3D12_COMPUTE_PIPELINE_STATE_DESC pd = {0};
    D3D12_COMMAND_QUEUE_DESC qd = {0};
    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 6, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE };
    uint32_t probes[NPROBES], (*got)[4];
    ID3D12RootSignature *rs;
    ID3D12PipelineState *pso_fill, *pso_probe;
    ID3D12DescriptorHeap *heap;
    ID3D12CommandAllocator *alloc;
    ID3D12GraphicsCommandList *list;
    ID3D12Fence *fence;
    ID3D12Resource *big, *probe_buf, *outbuf, *readback;
    ID3D12DescriptorHeap *h;
    ID3DBlob *blob = NULL, *err = NULL;
    D3D12_CPU_DESCRIPTOR_HANDLE cpu;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu;
    D3D12_RESOURCE_BARRIER b = {0};
    HANDLE event;
    HMODULE d3d12;
    UINT inc, i, v, bad[4] = {0}, first_bad[4];
    uint64_t elems = BUF_SIZE / 4;
    void *map;
    int np = 0;

    report = fopen(argc > 1 ? argv[1] : "bigbuf-report.txt", "w");
    out("Big-buffer check: one %.2f GB buffer read at large element indices\n", BUF_SIZE / 1073741824.0);

    /* probe positions: small ones, and both sides of every power of two from 2^20 up */
    probes[np++] = 0;
    probes[np++] = 1;
    probes[np++] = 12345;
    for (v = 20; v <= 29; v++)
    {
        uint64_t p = 1ull << v;

        if (p - 1 < elems)
            probes[np++] = (uint32_t)(p - 1);
        if (p < elems)
            probes[np++] = (uint32_t)p;
        if (p + 4 < elems)
            probes[np++] = (uint32_t)(p + 4);
    }
    probes[np++] = (uint32_t)(3ull << 27);
    probes[np++] = (uint32_t)(5ull << 26);
    probes[np++] = (uint32_t)(elems / 4 * 4 - 8);
    probes[np++] = (uint32_t)(elems - 1);
    while (np < NPROBES)
        probes[np] = probes[np - 1], np++;

    d3d12 = LoadLibraryA("d3d12.dll");
    create_device = d3d12 ? (void *)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    serialize = d3d12 ? (void *)GetProcAddress(d3d12, "D3D12SerializeRootSignature") : NULL;
    if (!create_device || !serialize || (FAILED(create_device(NULL, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&device))
            && FAILED(create_device(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device))))
        return out("FAILED: no D3D12 device\n"), 1;
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[0].DescriptorTable.NumDescriptorRanges = 2;
    params[0].DescriptorTable.pDescriptorRanges = ranges;
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    params[1].Descriptor.ShaderRegister = 1;
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
    params[2].Descriptor.ShaderRegister = 5;
    rsd.NumParameters = 3;
    rsd.pParameters = params;
    if (FAILED(serialize(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err))
            || FAILED(ID3D12Device_CreateRootSignature(device, 0, ID3D10Blob_GetBufferPointer(blob),
                    ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)&rs)))
        return out("FAILED: root signature\n"), 1;
    pd.pRootSignature = rs;
    pd.CS.pShaderBytecode = fill_dxil;
    pd.CS.BytecodeLength = sizeof(fill_dxil);
    if (FAILED(ID3D12Device_CreateComputePipelineState(device, &pd, &IID_ID3D12PipelineState, (void **)&pso_fill)))
        return out("FAILED: fill pipeline\n"), 1;
    pd.CS.pShaderBytecode = probe_dxil;
    pd.CS.BytecodeLength = sizeof(probe_dxil);
    if (FAILED(ID3D12Device_CreateComputePipelineState(device, &pd, &IID_ID3D12PipelineState, (void **)&pso_probe)))
        return out("FAILED: probe pipeline\n"), 1;
    if (FAILED(ID3D12Device_CreateCommandQueue(device, &qd, &IID_ID3D12CommandQueue, (void **)&queue))
            || FAILED(ID3D12Device_CreateDescriptorHeap(device, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap))
            || FAILED(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                    &IID_ID3D12CommandAllocator, (void **)&alloc))
            || FAILED(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL,
                    &IID_ID3D12GraphicsCommandList, (void **)&list))
            || FAILED(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence)))
        return out("FAILED: setup\n"), 1;

    if (!(big = make_buffer(D3D12_HEAP_TYPE_DEFAULT, BUF_SIZE, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS))
            || !(probe_buf = make_buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof(probes), D3D12_RESOURCE_FLAG_NONE,
                    D3D12_RESOURCE_STATE_GENERIC_READ))
            || !(outbuf = make_buffer(D3D12_HEAP_TYPE_DEFAULT, NPROBES * 16, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS))
            || !(readback = make_buffer(D3D12_HEAP_TYPE_READBACK, NPROBES * 16, D3D12_RESOURCE_FLAG_NONE,
                    D3D12_RESOURCE_STATE_COPY_DEST)))
        return 1;
    ID3D12Resource_Map(probe_buf, 0, NULL, &map);
    memcpy(map, probes, sizeof(probes));
    ID3D12Resource_Unmap(probe_buf, 0, NULL);

    h = heap;
    inc = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    h->lpVtbl->GetCPUDescriptorHandleForHeapStart(h, &cpu);
    h->lpVtbl->GetGPUDescriptorHandleForHeapStart(h, &gpu);
    for (i = 0; i < 5; i++)
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC sv = {0};
        D3D12_CPU_DESCRIPTOR_HANDLE c = { cpu.ptr + (SIZE_T)i * inc };

        sv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
        sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        switch (i)
        {
        case 0: sv.Format = DXGI_FORMAT_R32_UINT; sv.Buffer.NumElements = (UINT)elems; break;
        case 1: sv.Format = DXGI_FORMAT_R32G32B32A32_UINT; sv.Buffer.NumElements = (UINT)(elems / 4); break;
        case 2: sv.Buffer.NumElements = (UINT)elems; sv.Buffer.StructureByteStride = 4; break;
        case 3: sv.Format = DXGI_FORMAT_R32_TYPELESS; sv.Buffer.NumElements = (UINT)elems; sv.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_RAW; break;
        default: sv.Buffer.NumElements = NPROBES; sv.Buffer.StructureByteStride = 4; break;
        }
        ID3D12Device_CreateShaderResourceView(device, i == 4 ? probe_buf : big, &sv, c);
    }
    {
        D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {0};
        D3D12_CPU_DESCRIPTOR_HANDLE c = { cpu.ptr + 5 * (SIZE_T)inc };

        uv.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
        uv.Buffer.NumElements = NPROBES;
        uv.Buffer.StructureByteStride = 16;
        ID3D12Device_CreateUnorderedAccessView(device, outbuf, NULL, &uv, c);
    }

    ID3D12GraphicsCommandList_SetDescriptorHeaps(list, 1, &heap);
    ID3D12GraphicsCommandList_SetComputeRootSignature(list, rs);
    ID3D12GraphicsCommandList_SetComputeRootDescriptorTable(list, 0, gpu);
    ID3D12GraphicsCommandList_SetComputeRootUnorderedAccessView(list, 1, ID3D12Resource_GetGPUVirtualAddress(big));
    ID3D12GraphicsCommandList_SetComputeRootShaderResourceView(list, 2, ID3D12Resource_GetGPUVirtualAddress(probe_buf));
    ID3D12GraphicsCommandList_SetPipelineState(list, pso_fill);
    ID3D12GraphicsCommandList_Dispatch(list, NPROBES / 64, 1, 1);
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = big;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
    ID3D12GraphicsCommandList_SetPipelineState(list, pso_probe);
    ID3D12GraphicsCommandList_Dispatch(list, NPROBES / 64, 1, 1);
    b.Transition.pResource = outbuf;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
    ID3D12GraphicsCommandList_CopyResource(list, readback, outbuf);
    if (FAILED(ID3D12GraphicsCommandList_Close(list)))
        return out("FAILED: command list\n"), 1;
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    ID3D12CommandQueue_Signal(queue, fence, 1);
    event = CreateEventA(NULL, FALSE, FALSE, NULL);
    ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    if (WaitForSingleObject(event, 120000) != WAIT_OBJECT_0)
        return out("FAILED: the GPU didn't finish within 2 minutes\n"), 1;
    if (FAILED(ID3D12Resource_Map(readback, 0, NULL, &map)))
        return out("FAILED: map\n"), 1;
    got = map;

    out("\n%-12s %-10s  %-10s  %-10s  %-10s  %-10s\n", "element", "expected", "R32_UINT", "RGBA32_UINT", "structured", "raw");
    for (i = 0; i < (UINT)np && (i == 0 || probes[i] != probes[i - 1]); i++)
    {
        uint32_t want = expect(probes[i]);
        char mark[4] = "    ";

        for (v = 0; v < 4; v++)
            if (got[i][v] != want)
            {
                if (!bad[v]++)
                    first_bad[v] = probes[i];
                mark[v] = '*';
            }
        out("%-12u %08x    %08x%c   %08x%c    %08x%c    %08x%c\n", probes[i], want, got[i][0], mark[0], got[i][1], mark[1],
                got[i][2], mark[2], got[i][3], mark[3]);
    }
    out("\n");
    for (v = 0; v < 4; v++)
    {
        if (bad[v])
            out("%-24s WRONG at %u probe(s), first at element %u (= 2^%.2f)\n", view_names[v], bad[v], first_bad[v],
                    first_bad[v] ? __builtin_log2((double)first_bad[v]) : 0.0);
        else
            out("%-24s ok\n", view_names[v]);
    }
    out("RESULT: %s\n", bad[0] || bad[1] || bad[2] || bad[3] ? "SOME VIEWS READ WRONG DATA AT LARGE INDICES" : "all views read correctly");
    return 0;
}
