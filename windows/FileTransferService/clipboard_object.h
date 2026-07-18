#pragma once

/// @file clipboard_object.h
/// IDataObject implementation providing CF_HDROP + CFSTR_FILECONTENTS
/// + CFSTR_PREFERREDDROPEFFECT for clipboard paste integration.
///
/// After a file upload completes, the service sets this IDataObject on
/// the Windows clipboard so the user (or automated Ctrl+V) can paste
/// the file into the streamed application.

#include <Windows.h>
#include <objidl.h>
#include <oleidl.h>
#include <shlobj.h>

#include <cstdint>
#include <string>
#include <vector>

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// FileDataObject
// ══════════════════════════════════════════════════════════════════════════════
//
// Implements IDataObject with three formats:
//   CF_HDROP               — DROPFILES struct with file path
//   CFSTR_FILECONTENTS     — IStream backed by the on-disk file (TYMED_ISTREAM)
//   CFSTR_PREFERREDDROPEFFECT — DROPEFFECT_COPY
//
class FileDataObject final : public IDataObject {
public:
    FileDataObject(const std::wstring& filePath);
    ~FileDataObject() override = default;

    // IUnknown
    ULONG AddRef() override;
    ULONG Release() override;
    HRESULT QueryInterface(REFIID riid, void** ppv) override;

    // IDataObject
    HRESULT GetData(FORMATETC* pFormatEtc, STGMEDIUM* pMedium) override;
    HRESULT GetDataHere(FORMATETC*, STGMEDIUM*) override;
    HRESULT QueryGetData(FORMATETC* pFormatEtc) override;
    HRESULT GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override;
    HRESULT SetData(FORMATETC*, STGMEDIUM*, BOOL) override;
    HRESULT EnumFormatEtc(DWORD dwDirection, IEnumFORMATETC** ppEnum) override;
    HRESULT DAdvise(FORMATETC*, ADVF, IAdviseSink*, DWORD*) override;
    HRESULT DUnadvise(DWORD) override;
    HRESULT EnumDAdvise(IEnumSTATDATA**) override;

private:
    LONG m_refCount{1};
    std::wstring m_filePath;

    // FORMATETC for all supported formats.
    static constexpr UINT kFormatCount = 3;
    FORMATETC m_formats[3]{};

    // Build FORMATETC entries on init.
    void InitFormats();

    // Stream implementation for CFSTR_FILECONTENTS.
    class FileStream final : public IStream {
    public:
        FileStream(const std::wstring& path);
        ~FileStream() override;

        ULONG AddRef() override;
        ULONG Release() override;
        HRESULT QueryInterface(REFIID riid, void** ppv) override;

        HRESULT Read(void* pv, ULONG cb, ULONG* pcbRead) override;
        HRESULT Write(const void*, ULONG, ULONG*) override;
        HRESULT Seek(LARGE_INTEGER dlibMove, DWORD dwOrigin,
                     ULARGE_INTEGER* plibNewPosition) override;
        HRESULT SetSize(ULARGE_INTEGER) override;
        HRESULT CopyTo(IStream*, ULARGE_INTEGER, ULARGE_INTEGER*,
                       ULARGE_INTEGER*) override;
        HRESULT Commit(DWORD) override;
        HRESULT Revert() override;
        HRESULT LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override;
        HRESULT UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override;
        HRESULT Stat(STATSTG* pStatstg, DWORD grfStatFlag) override;
        HRESULT Clone(IStream**) override;

    private:
        LONG m_refCount{1};
        HANDLE m_hFile{INVALID_HANDLE_VALUE};
        LARGE_INTEGER m_position{};
        uint64_t m_fileSize{};
    };
};

} // namespace solstream::filetransfer
