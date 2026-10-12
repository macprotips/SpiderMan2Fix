/* A stand-in for Spider-Man2.exe that loads the fix's d3d12.dll (with mock_d3d12.dll as
 * the "real" driver) and checks it changes exactly what it should, and nothing when
 * the settings don't match.
 *   fix_game.exe match|other-build|missing-shader|no-ini */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include "../../shim/sm2fix_core.h"

static int failures;
#define CHECK(x) do { if (!(x)) { printf("FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)

static const char shader_a[] = "stand-in-for-CS_ModelSkinning-reading-the-pool";
static const char shader_b[] = "stand-in-for-the-morph-shader-made-through-a-stream";
static const char other[] = "some-unrelated-compute-shader";
static const char raw_a[] = "DXBC-rewritten-skinning-shader-raw-loads";
static const char raw_b[] = "DXBC-rewritten-morph-shader-raw-loads";

struct sub_ptr { UINT type; void *ptr; };
struct sub_bytecode { UINT type; UINT pad; const void *code; SIZE_T size; };

static void write_file(const char *name, const void *data, size_t size)
{
    FILE *f = fopen(name, "wb");
    fwrite(data, 1, size, f);
    fclose(f);
}

static int thread_count(void)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te = { sizeof(te) };
    int n = 0;

    if (Thread32First(snap, &te))
        do if (te.th32OwnerProcessID == GetCurrentProcessId()) n++; while (Thread32Next(snap, &te));
    CloseHandle(snap);
    return n;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "match";
    int active = !strcmp(mode, "match");
    const IMAGE_DOS_HEADER *dos = (const void *)GetModuleHandleW(NULL);
    const IMAGE_NT_HEADERS64 *nt = (const void *)((const BYTE *)dos + dos->e_lfanew);
    HRESULT (WINAPI *create)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    unsigned long long (*last_cs)(void);
    void (*last_srv)(D3D12_SHADER_RESOURCE_VIEW_DESC *);
    void (*last_uav)(D3D12_UNORDERED_ACCESS_VIEW_DESC *);
    char ini[256], name[64];
    ID3D12Device2 *device;
    ID3D12PipelineState *pso;
    D3D12_COMPUTE_PIPELINE_STATE_DESC cdesc = {0};
    D3D12_PIPELINE_STATE_STREAM_DESC sdesc;
    struct { struct sub_ptr root; struct sub_bytecode cs; } stream = {{0, NULL}, {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS, 0, shader_b, sizeof(shader_b)}};
    D3D12_SHADER_RESOURCE_VIEW_DESC sv = {0}, got;
    D3D12_CPU_DESCRIPTOR_HANDLE cpu = {0};
    HMODULE fix, mock;
    int threads_before;

    /* what the app writes */
    DeleteFileA("sm2fix.ini");
    DeleteFileA("sm2fix.log");
    snprintf(ini, sizeof(ini), "# written by the app\ngame_build = %08lx-%08lx\nshaders = %016llx %016llx\n",
            (unsigned long)nt->FileHeader.TimeDateStamp + (!strcmp(mode, "other-build") ? 1 : 0),
            (unsigned long)nt->OptionalHeader.SizeOfImage,
            (unsigned long long)sm2_shader_hash(shader_a, sizeof(shader_a)),
            (unsigned long long)sm2_shader_hash(shader_b, sizeof(shader_b)));
    if (strcmp(mode, "no-ini"))
        write_file("sm2fix.ini", ini, strlen(ini));
    snprintf(name, sizeof(name), "sm2fix-pool-%016llx.dxil", (unsigned long long)sm2_shader_hash(shader_a, sizeof(shader_a)));
    write_file(name, raw_a, strlen(raw_a));
    snprintf(name, sizeof(name), "sm2fix-pool-%016llx.dxil", (unsigned long long)sm2_shader_hash(shader_b, sizeof(shader_b)));
    if (strcmp(mode, "missing-shader"))
        write_file(name, raw_b, strlen(raw_b));
    else
        DeleteFileA(name);

    SetEnvironmentVariableA("SM2FIX_REAL_D3D12", "mock_d3d12.dll");
    mock = LoadLibraryA("mock_d3d12.dll");
    threads_before = thread_count();
    fix = LoadLibraryA("d3d12.dll");
    CHECK(fix && fix != mock);
    create = (void *)GetProcAddress(fix, "D3D12CreateDevice");
    last_cs = (void *)GetProcAddress(mock, "mock_get_last_cs_hash");
    last_srv = (void *)GetProcAddress(mock, "mock_get_last_srv");
    last_uav = (void *)GetProcAddress(mock, "mock_get_last_uav");
    CHECK(create && last_cs && last_srv && last_uav);
    if (!create || !last_cs || !last_srv || !last_uav || FAILED(create(NULL, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device2, (void **)&device)))
    {
        printf("%s: FAILED, no device\n", mode);
        return 1;
    }

    /* compute pipeline: shader A -> its rewritten copy; others untouched */
    cdesc.CS.pShaderBytecode = shader_a;
    cdesc.CS.BytecodeLength = sizeof(shader_a);
    CHECK(SUCCEEDED(ID3D12Device2_CreateComputePipelineState(device, &cdesc, &IID_ID3D12PipelineState, (void **)&pso)));
    CHECK(last_cs() == (active ? sm2_shader_hash(raw_a, strlen(raw_a)) : sm2_shader_hash(shader_a, sizeof(shader_a))));
    cdesc.CS.pShaderBytecode = other;
    cdesc.CS.BytecodeLength = sizeof(other);
    CHECK(SUCCEEDED(ID3D12Device2_CreateComputePipelineState(device, &cdesc, &IID_ID3D12PipelineState, (void **)&pso)));
    CHECK(last_cs() == sm2_shader_hash(other, sizeof(other)));

    /* pipeline stream: shader B -> its rewritten copy; the game's stream is not modified */
    sdesc.SizeInBytes = sizeof(stream);
    sdesc.pPipelineStateSubobjectStream = &stream;
    CHECK(SUCCEEDED(ID3D12Device2_CreatePipelineState(device, &sdesc, &IID_ID3D12PipelineState, (void **)&pso)));
    CHECK(last_cs() == (active ? sm2_shader_hash(raw_b, strlen(raw_b)) : sm2_shader_hash(shader_b, sizeof(shader_b))));
    CHECK(stream.cs.code == shader_b && stream.cs.size == sizeof(shader_b));

    /* the game's 536M-element typed view -> raw; others untouched */
    sv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
    sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    sv.Format = DXGI_FORMAT_R32_UINT;
    sv.Buffer.NumElements = 536346624;
    ID3D12Device2_CreateShaderResourceView(device, NULL, &sv, cpu);
    last_srv(&got);
    CHECK(got.Format == (active ? DXGI_FORMAT_R32_TYPELESS : DXGI_FORMAT_R32_UINT));
    CHECK(got.Buffer.Flags == (active ? D3D12_BUFFER_SRV_FLAG_RAW : 0));
    CHECK(got.Buffer.NumElements == 536346624 && sv.Format == DXGI_FORMAT_R32_UINT);
    sv.Buffer.NumElements = 1u << 28;
    ID3D12Device2_CreateShaderResourceView(device, NULL, &sv, cpu);
    last_srv(&got);
    CHECK(got.Format == DXGI_FORMAT_R32_UINT && !got.Buffer.Flags);
    sv.Format = DXGI_FORMAT_R32G32B32A32_UINT;
    sv.Buffer.NumElements = 134086656;
    ID3D12Device2_CreateShaderResourceView(device, NULL, &sv, cpu);
    last_srv(&got);
    CHECK(got.Format == DXGI_FORMAT_R32G32B32A32_UINT && !got.Buffer.Flags);

    /* the game's 536M-element typed UAV (the symbiote's index writes) -> raw; others untouched */
    {
        D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {0}, ugot;
        ID3D12Resource *counter = (ID3D12Resource *)&uv;   /* never used by the mock, only compared to NULL */

        uv.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
        uv.Format = DXGI_FORMAT_R32_UINT;
        uv.Buffer.NumElements = 536346624;
        ID3D12Device2_CreateUnorderedAccessView(device, NULL, NULL, &uv, cpu);
        last_uav(&ugot);
        CHECK(ugot.Format == (active ? DXGI_FORMAT_R32_TYPELESS : DXGI_FORMAT_R32_UINT));
        CHECK(ugot.Buffer.Flags == (active ? D3D12_BUFFER_UAV_FLAG_RAW : 0));
        CHECK(ugot.Buffer.NumElements == 536346624 && uv.Format == DXGI_FORMAT_R32_UINT);
        uv.Buffer.NumElements = 1u << 28;
        ID3D12Device2_CreateUnorderedAccessView(device, NULL, NULL, &uv, cpu);
        last_uav(&ugot);
        CHECK(ugot.Format == DXGI_FORMAT_R32_UINT && !ugot.Buffer.Flags);
        uv.Buffer.NumElements = 536346624;
        ID3D12Device2_CreateUnorderedAccessView(device, NULL, counter, &uv, cpu);
        last_uav(&ugot);
        CHECK(ugot.Format == DXGI_FORMAT_R32_UINT && !ugot.Buffer.Flags);
        uv.Format = DXGI_FORMAT_R16_UINT;
        uv.Buffer.NumElements = 1072693248;
        ID3D12Device2_CreateUnorderedAccessView(device, NULL, NULL, &uv, cpu);
        last_uav(&ugot);
        CHECK(ugot.Format == DXGI_FORMAT_R16_UINT && !ugot.Buffer.Flags);
        uv.Format = DXGI_FORMAT_R32G32B32A32_UINT;
        uv.Buffer.NumElements = 134086656;
        ID3D12Device2_CreateUnorderedAccessView(device, NULL, NULL, &uv, cpu);
        last_uav(&ugot);
        CHECK(ugot.Format == DXGI_FORMAT_R32G32B32A32_UINT && !ugot.Buffer.Flags);
    }

    /* no threads of its own */
    CHECK(thread_count() == threads_before);

    printf("%s: %s\n", mode, failures ? "FAILED" : "ok");
    return failures != 0;
}
