/* Spider-Man 2 T-Pose Fix: the d3d12.dll the Mac app installs next to Spider-Man2.exe.
 *
 * D3DMetal on M1-M4 Macs reads typed buffer views only up to element 2^28 (later reads
 * return 0), and drops typed writes past it. The game reads its 2 GB character mesh pool
 * through typed R32 views of ~536M elements, so meshes stored high in the pool are never
 * skinned (T-pose); and it writes the symbiote's triangles into the pool through a typed
 * R32 UAV of the same size, past element 2^28, so they are lost (spikes, or no symbiote).
 *
 * Wine loads this DLL instead of the system d3d12.dll (a per-game DLL override set by
 * the app). It forwards everything to the real d3d12.dll and changes exactly two things:
 *   1. typed 32-bit buffer SRVs and UAVs wider than 2^28 elements are created as raw views;
 *   2. the game shaders that read or write those views are replaced by rewritten copies
 *      whose accesses are raw (sm2fix-pool-<hash>.dxil, built by the app from the game's exe).
 * It does that only when sm2fix.ini says it was set up for this exact game build and
 * every listed shader file is present; otherwise it changes nothing. It starts no
 * threads, hooks nothing else and never reads or writes the game's code or data.
 * It writes sm2fix.log next to itself, replaced on every launch. */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "sm2fix_core.h"

#define FIX_VERSION "1.0"
#define WIDE_VIEW (1u << 28)          /* D3DMetal's typed buffer limit on M1-M4 */
#define MAX_SHADERS 8
#define DEV_IDX(m) (offsetof(ID3D12Device2Vtbl, m) / sizeof(void *))

static HMODULE g_self, g_real;
static FILE *g_log;
static SRWLOCK g_lock = SRWLOCK_INIT;
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;
static BOOL g_active;
static struct { uint64_t hash; void *data; size_t size; } g_shaders[MAX_SHADERS];
static unsigned int g_shader_count;
static volatile LONG g_views, g_uavs, g_pipelines;
static struct { void **vtbl; unsigned int index; void *orig; } g_hooks[32];
static unsigned int g_hook_count;

static void log_msg(const char *fmt, ...)
{
    va_list args;

    if (!g_log)
        return;
    AcquireSRWLockExclusive(&g_lock);
    va_start(args, fmt);
    vfprintf(g_log, fmt, args);
    va_end(args);
    fputc('\n', g_log);
    fflush(g_log);
    ReleaseSRWLockExclusive(&g_lock);
}

static void path_next_to_self(WCHAR *out, size_t len, const WCHAR *file)
{
    WCHAR *slash;

    GetModuleFileNameW(g_self, out, (DWORD)len);
    slash = wcsrchr(out, L'\\');
    if (!slash)
        slash = wcsrchr(out, L'/');
    if (slash)
        slash[1] = 0;
    else
        out[0] = 0;
    wcsncat(out, file, len - wcslen(out) - 1);
}

static void *read_file(const WCHAR *path, size_t *size)
{
    void *data = NULL;
    FILE *f = _wfopen(path, L"rb");
    long n;

    *size = 0;
    if (!f)
        return NULL;
    if (!fseek(f, 0, SEEK_END) && (n = ftell(f)) > 0 && !fseek(f, 0, SEEK_SET) && (data = malloc((size_t)n)))
    {
        if (fread(data, 1, (size_t)n, f) == (size_t)n)
            *size = (size_t)n;
        else
        {
            free(data);
            data = NULL;
        }
    }
    fclose(f);
    return data;
}

/* The running game's build: PE timestamp and image size of Spider-Man2.exe. The app
 * reads the same two fields from the file and writes them to sm2fix.ini. */
static void game_build(char *out, size_t len)
{
    const BYTE *base = (const BYTE *)GetModuleHandleW(NULL);
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);

    snprintf(out, len, "%08lx-%08lx", (unsigned long)nt->FileHeader.TimeDateStamp,
            (unsigned long)nt->OptionalHeader.SizeOfImage);
}

/* sm2fix.ini: "game_build = <build>" and "shaders = <hash> <hash> ..." */
static int read_settings(char *build, size_t build_len, uint64_t *hashes, unsigned int *count)
{
    WCHAR path[MAX_PATH];
    char line[512];
    FILE *f;

    *count = 0;
    build[0] = 0;
    path_next_to_self(path, MAX_PATH, L"sm2fix.ini");
    if (!(f = _wfopen(path, L"r")))
        return 0;
    while (fgets(line, sizeof(line), f))
    {
        char *value = strchr(line, '='), *end;

        if (line[0] == '#' || !value)
            continue;
        *value++ = 0;
        while (*value == ' ' || *value == '\t')
            value++;
        value[strcspn(value, "\r\n")] = 0;
        if (!strncmp(line, "game_build", 10))
            snprintf(build, build_len, "%s", value);
        else if (!strncmp(line, "shaders", 7))
        {
            while (*value && *count < MAX_SHADERS)
            {
                uint64_t h = strtoull(value, &end, 16);
                if (end == value)
                    break;
                hashes[(*count)++] = h;
                value = end + strspn(end, " ,\t");
            }
        }
    }
    fclose(f);
    return 1;
}

/* Decides once whether to apply the fix, and loads the real d3d12.dll. */
static BOOL CALLBACK init_once(INIT_ONCE *once, void *param, void **context)
{
    WCHAR path[MAX_PATH], name[64];
    char running[32], expected[64] = "";
    uint64_t hashes[MAX_SHADERS];
    unsigned int count = 0, i;
    char test_real[MAX_PATH] = "";   /* tests only: SM2FIX_REAL_D3D12 names a stand-in driver */

    path_next_to_self(path, MAX_PATH, L"sm2fix.log");
    g_log = _wfopen(path, L"w");
    log_msg("Spider-Man 2 T-Pose Fix " FIX_VERSION);

    if (GetEnvironmentVariableA("SM2FIX_REAL_D3D12", test_real, sizeof(test_real)) && test_real[0])
        g_real = LoadLibraryA(test_real);
    else if (GetSystemDirectoryW(path, MAX_PATH - 12))
    {
        wcscat(path, L"\\d3d12.dll");
        g_real = LoadLibraryW(path);
    }
    if (!g_real || g_real == g_self)
    {
        log_msg("ERROR: couldn't load the system d3d12.dll (error %lu)", GetLastError());
        g_real = NULL;
        return TRUE;
    }

    game_build(running, sizeof(running));
    if (!read_settings(expected, sizeof(expected), hashes, &count))
        log_msg("No sm2fix.ini: not applying the fix.");
    else if (strcmp(running, expected))
        log_msg("This game build is %s, the fix was set up for %s (the game was updated). Not applying the fix;"
                " open the Spider-Man 2 T-Pose Fix app and click Update Fix.", running, expected[0] ? expected : "none");
    else if (!count)
        log_msg("sm2fix.ini lists no shaders: not applying the fix.");
    else
    {
        g_active = TRUE;
        for (i = 0; i < count; i++)
        {
            size_t size;
            void *data;

            swprintf(name, ARRAYSIZE(name), L"sm2fix-pool-%016llx.dxil", (unsigned long long)hashes[i]);
            path_next_to_self(path, MAX_PATH, name);
            data = read_file(path, &size);
            if (!data || size < 32 || memcmp(data, "DXBC", 4))
            {
                log_msg("Missing or damaged %ls: not applying the fix.", name);
                free(data);
                g_active = FALSE;
                break;
            }
            g_shaders[g_shader_count].hash = hashes[i];
            g_shaders[g_shader_count].data = data;
            g_shaders[g_shader_count].size = size;
            g_shader_count++;
        }
        if (g_active)
            log_msg("Game build %s matches. Applying the fix (%u shaders).", running, g_shader_count);
    }
    return TRUE;
}

static void ensure_init(void)
{
    InitOnceExecuteOnce(&g_init, init_once, NULL, NULL);
}

/* ---------------------------------------------------------------- vtable hooks */

static void *orig_fn(void *obj, unsigned int index)
{
    void **vtbl = *(void ***)obj, *fn = NULL;
    unsigned int i;

    AcquireSRWLockShared(&g_lock);
    for (i = 0; i < g_hook_count; i++)
        if (g_hooks[i].vtbl == vtbl && g_hooks[i].index == index)
            fn = g_hooks[i].orig;
    ReleaseSRWLockShared(&g_lock);
    return fn;
}

static void hook_slot(void *obj, unsigned int index, void *hook)
{
    void **vtbl = *(void ***)obj;
    DWORD old;
    unsigned int i;

    AcquireSRWLockExclusive(&g_lock);
    for (i = 0; i < g_hook_count; i++)
        if (g_hooks[i].vtbl == vtbl && g_hooks[i].index == index)
            goto done;
    if (g_hook_count == ARRAYSIZE(g_hooks) || !vtbl[index] || vtbl[index] == hook
            || !VirtualProtect(&vtbl[index], sizeof(void *), PAGE_READWRITE, &old))
        goto done;
    g_hooks[g_hook_count].vtbl = vtbl;
    g_hooks[g_hook_count].index = index;
    g_hooks[g_hook_count].orig = vtbl[index];
    g_hook_count++;
    vtbl[index] = hook;
    VirtualProtect(&vtbl[index], sizeof(void *), old, &old);
done:
    ReleaseSRWLockExclusive(&g_lock);
}

/* The rewritten copy of a shader, if it is one of the fix's. */
static const void *replacement(const void *code, size_t size, size_t *out_size)
{
    uint64_t hash;
    unsigned int i;

    if (!code || size < 32)
        return NULL;
    hash = sm2_shader_hash(code, size);
    for (i = 0; i < g_shader_count; i++)
    {
        if (g_shaders[i].hash == hash)
        {
            *out_size = g_shaders[i].size;
            return g_shaders[i].data;
        }
    }
    return NULL;
}

static HRESULT STDMETHODCALLTYPE hk_CreateComputePipelineState(ID3D12Device *device,
        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **pso)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device *, const D3D12_COMPUTE_PIPELINE_STATE_DESC *, REFIID, void **)
            = orig_fn(device, DEV_IDX(CreateComputePipelineState));
    const void *alt;
    size_t alt_size;

    if (desc && (alt = replacement(desc->CS.pShaderBytecode, desc->CS.BytecodeLength, &alt_size)))
    {
        D3D12_COMPUTE_PIPELINE_STATE_DESC copy = *desc;
        HRESULT hr;

        copy.CS.pShaderBytecode = alt;
        copy.CS.BytecodeLength = alt_size;
        hr = orig(device, &copy, riid, pso);
        log_msg("Replaced shader %016llx: %s", (unsigned long long)sm2_shader_hash(desc->CS.pShaderBytecode,
                desc->CS.BytecodeLength), SUCCEEDED(hr) ? "ok" : "FAILED, using the game's own");
        if (SUCCEEDED(hr))
        {
            InterlockedIncrement(&g_pipelines);
            return hr;
        }
    }
    return orig(device, desc, riid, pso);
}

static HRESULT STDMETHODCALLTYPE hk_CreatePipelineState(ID3D12Device2 *device,
        const D3D12_PIPELINE_STATE_STREAM_DESC *desc, REFIID riid, void **pso)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device2 *, const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **)
            = orig_fn(device, DEV_IDX(CreatePipelineState));
    const void *code = NULL, *alt;
    size_t size = 0, alt_size;
    long at;

    if (desc && sm2_stream_find_cs(desc->pPipelineStateSubobjectStream, desc->SizeInBytes, &code, &size) == SM2_STREAM_COMPUTE
            && (alt = replacement(code, size, &alt_size))
            && (at = sm2_stream_cs_offset(desc->pPipelineStateSubobjectStream, desc->SizeInBytes)) >= 0)
    {
        BYTE *copy = malloc(desc->SizeInBytes);
        D3D12_PIPELINE_STATE_STREAM_DESC patched = *desc;
        UINT64 len = alt_size;
        HRESULT hr;

        if (copy)
        {
            memcpy(copy, desc->pPipelineStateSubobjectStream, desc->SizeInBytes);
            memcpy(copy + at + 8, &alt, sizeof(alt));
            memcpy(copy + at + 16, &len, sizeof(len));
            patched.pPipelineStateSubobjectStream = copy;
            hr = orig(device, &patched, riid, pso);
            free(copy);
            log_msg("Replaced shader %016llx: %s", (unsigned long long)sm2_shader_hash(code, size),
                    SUCCEEDED(hr) ? "ok" : "FAILED, using the game's own");
            if (SUCCEEDED(hr))
            {
                InterlockedIncrement(&g_pipelines);
                return hr;
            }
        }
    }
    return orig(device, desc, riid, pso);
}

static void STDMETHODCALLTYPE hk_CreateShaderResourceView(ID3D12Device *device, ID3D12Resource *resource,
        const D3D12_SHADER_RESOURCE_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE handle)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12Device *, ID3D12Resource *, const D3D12_SHADER_RESOURCE_VIEW_DESC *,
            D3D12_CPU_DESCRIPTOR_HANDLE) = orig_fn(device, DEV_IDX(CreateShaderResourceView));

    if (desc && desc->ViewDimension == D3D12_SRV_DIMENSION_BUFFER && desc->Buffer.NumElements > WIDE_VIEW
            && !(desc->Buffer.Flags & D3D12_BUFFER_SRV_FLAG_RAW)
            && (desc->Format == DXGI_FORMAT_R32_UINT || desc->Format == DXGI_FORMAT_R32_SINT
                || desc->Format == DXGI_FORMAT_R32_FLOAT))
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC raw = *desc;

        raw.Format = DXGI_FORMAT_R32_TYPELESS;
        raw.Buffer.Flags |= D3D12_BUFFER_SRV_FLAG_RAW;
        raw.Buffer.StructureByteStride = 0;
        if (InterlockedIncrement(&g_views) <= 4)
            log_msg("Wide typed view (%u elements) created as a raw view", desc->Buffer.NumElements);
        orig(device, resource, &raw, handle);
        return;
    }
    orig(device, resource, desc, handle);
}

static void STDMETHODCALLTYPE hk_CreateUnorderedAccessView(ID3D12Device *device, ID3D12Resource *resource,
        ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE handle)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12Device *, ID3D12Resource *, ID3D12Resource *,
            const D3D12_UNORDERED_ACCESS_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE)
            = orig_fn(device, DEV_IDX(CreateUnorderedAccessView));

    if (desc && desc->ViewDimension == D3D12_UAV_DIMENSION_BUFFER && desc->Buffer.NumElements > WIDE_VIEW
            && !counter && !(desc->Buffer.Flags & D3D12_BUFFER_UAV_FLAG_RAW)
            && (desc->Format == DXGI_FORMAT_R32_UINT || desc->Format == DXGI_FORMAT_R32_SINT
                || desc->Format == DXGI_FORMAT_R32_FLOAT))
    {
        D3D12_UNORDERED_ACCESS_VIEW_DESC raw = *desc;

        raw.Format = DXGI_FORMAT_R32_TYPELESS;
        raw.Buffer.Flags |= D3D12_BUFFER_UAV_FLAG_RAW;
        raw.Buffer.StructureByteStride = 0;
        raw.Buffer.CounterOffsetInBytes = 0;
        if (InterlockedIncrement(&g_uavs) <= 4)
            log_msg("Wide typed UAV (%u elements) created as a raw view", desc->Buffer.NumElements);
        orig(device, resource, counter, &raw, handle);
        return;
    }
    orig(device, resource, counter, desc, handle);
}

static void hook_device(IUnknown *device)
{
    static const struct { const IID *iid; int has_stream; } ifaces[] =
    {
        {&IID_ID3D12Device, 0}, {&IID_ID3D12Device1, 0}, {&IID_ID3D12Device2, 1}, {&IID_ID3D12Device3, 1},
        {&IID_ID3D12Device4, 1}, {&IID_ID3D12Device5, 1}, {&IID_ID3D12Device6, 1}, {&IID_ID3D12Device7, 1},
        {&IID_ID3D12Device8, 1}, {&IID_ID3D12Device9, 1}, {&IID_ID3D12Device10, 1},
    };
    unsigned int i;

    for (i = 0; i < ARRAYSIZE(ifaces); i++)
    {
        IUnknown *iface = NULL;

        if (FAILED(device->lpVtbl->QueryInterface(device, ifaces[i].iid, (void **)&iface)) || !iface)
            continue;
        hook_slot(iface, DEV_IDX(CreateComputePipelineState), (void *)hk_CreateComputePipelineState);
        hook_slot(iface, DEV_IDX(CreateShaderResourceView), (void *)hk_CreateShaderResourceView);
        hook_slot(iface, DEV_IDX(CreateUnorderedAccessView), (void *)hk_CreateUnorderedAccessView);
        if (ifaces[i].has_stream)
            hook_slot(iface, DEV_IDX(CreatePipelineState), (void *)hk_CreatePipelineState);
        iface->lpVtbl->Release(iface);
    }
}

/* ------------------------------------------------------------------ exports */

#define REAL(name, type) ((type)(g_real ? (void *)GetProcAddress(g_real, #name) : NULL))

HRESULT WINAPI fix_D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **device)
{
    HRESULT (WINAPI *real)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    HRESULT hr;

    ensure_init();
    if (!(real = REAL(D3D12CreateDevice, HRESULT (WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **))))
        return E_FAIL;
    hr = real(adapter, level, riid, device);
    if (SUCCEEDED(hr) && g_active && device && *device)
        hook_device(*device);
    return hr;
}

HRESULT WINAPI fix_D3D12GetDebugInterface(REFIID riid, void **out)
{
    HRESULT (WINAPI *real)(REFIID, void **);

    ensure_init();
    return (real = REAL(D3D12GetDebugInterface, HRESULT (WINAPI *)(REFIID, void **))) ? real(riid, out) : E_NOINTERFACE;
}

HRESULT WINAPI fix_D3D12SerializeRootSignature(const void *desc, int version, void **blob, void **error)
{
    HRESULT (WINAPI *real)(const void *, int, void **, void **);

    ensure_init();
    return (real = REAL(D3D12SerializeRootSignature, HRESULT (WINAPI *)(const void *, int, void **, void **)))
            ? real(desc, version, blob, error) : E_FAIL;
}

HRESULT WINAPI fix_D3D12SerializeVersionedRootSignature(const void *desc, void **blob, void **error)
{
    HRESULT (WINAPI *real)(const void *, void **, void **);

    ensure_init();
    return (real = REAL(D3D12SerializeVersionedRootSignature, HRESULT (WINAPI *)(const void *, void **, void **)))
            ? real(desc, blob, error) : E_FAIL;
}

HRESULT WINAPI fix_D3D12CreateRootSignatureDeserializer(const void *data, SIZE_T size, REFIID riid, void **out)
{
    HRESULT (WINAPI *real)(const void *, SIZE_T, REFIID, void **);

    ensure_init();
    return (real = REAL(D3D12CreateRootSignatureDeserializer, HRESULT (WINAPI *)(const void *, SIZE_T, REFIID, void **)))
            ? real(data, size, riid, out) : E_FAIL;
}

HRESULT WINAPI fix_D3D12CreateVersionedRootSignatureDeserializer(const void *data, SIZE_T size, REFIID riid, void **out)
{
    HRESULT (WINAPI *real)(const void *, SIZE_T, REFIID, void **);

    ensure_init();
    return (real = REAL(D3D12CreateVersionedRootSignatureDeserializer, HRESULT (WINAPI *)(const void *, SIZE_T, REFIID, void **)))
            ? real(data, size, riid, out) : E_FAIL;
}

HRESULT WINAPI fix_D3D12EnableExperimentalFeatures(UINT count, const IID *iids, void *structs, UINT *sizes)
{
    HRESULT (WINAPI *real)(UINT, const IID *, void *, UINT *);

    ensure_init();
    return (real = REAL(D3D12EnableExperimentalFeatures, HRESULT (WINAPI *)(UINT, const IID *, void *, UINT *)))
            ? real(count, iids, structs, sizes) : E_NOINTERFACE;
}

HRESULT WINAPI fix_D3D12GetInterface(REFCLSID clsid, REFIID riid, void **out)
{
    HRESULT (WINAPI *real)(REFCLSID, REFIID, void **);

    ensure_init();
    return (real = REAL(D3D12GetInterface, HRESULT (WINAPI *)(REFCLSID, REFIID, void **))) ? real(clsid, riid, out) : E_NOINTERFACE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_self = instance;
        DisableThreadLibraryCalls(instance);
    }
    else if (reason == DLL_PROCESS_DETACH && g_log)
    {
        if (g_active)
            fprintf(g_log, "Exit: %ld shaders replaced, %ld wide views and %ld wide UAVs made raw\n", (long)g_pipelines,
                    (long)g_views, (long)g_uavs);
        fclose(g_log);
        g_log = NULL;
    }
    return TRUE;
}
