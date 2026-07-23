#include "clipboard_object.h"

#include <cstring>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// FileDataObject
// ══════════════════════════════════════════════════════════════════════════════

FileDataObject::FileDataObject(const std::wstring& filePath)
    : m_filePath(filePath)
{
    InitFormats();
}

void FileDataObject::InitFormats() {
    // 1. CF_HDROP — DROPFILES struct with path.
    m_formats[0] = {
        CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL
    };
    // 2. CFSTR_FILECONTENTS — IStream.
    m_formats[1] = {
        static_cast<CLIPFORMAT>(
            RegisterClipboardFormatW(L"FileContents")),
        nullptr, DVASPECT_CONTENT, 0, TYMED_ISTREAM
    };
    // 3. CFSTR_PREFERREDDROPEFFECT — DROPEFFECT_COPY.
    m_formats[2] = {
        static_cast<CLIPFORMAT>(
            RegisterClipboardFormatW(L"Preferred DropEffect")),
        nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL
    };
}

// ── IUnknown ────────────────────────────────────────────────────────────────

ULONG FileDataObject::AddRef() {
    return InterlockedIncrement(&m_refCount);
}

ULONG FileDataObject::Release() {
    ULONG ref = InterlockedDecrement(&m_refCount);
    if (ref == 0)
        delete this;
    return ref;
}

HRESULT FileDataObject::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;

    if (riid == IID_IUnknown || riid == IID_IDataObject) {
        *ppv = static_cast<IDataObject*>(this);
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

// ── IDataObject ────────────────────────────────────────────────────────────

HRESULT FileDataObject::GetData(FORMATETC* pFE, STGMEDIUM* pMed) {
    if (!pFE || !pMed) return E_INVALIDARG;
    pMed->hGlobal = nullptr;
    pMed->pUnkForRelease = nullptr;

    // CF_HDROP
    if (pFE->cfFormat == CF_HDROP && (pFE->tymed & TYMED_HGLOBAL)) {
        // Calculate required size: DROPFILES + path + 2 nulls
        size_t pathBytes = (m_filePath.size() + 1) * sizeof(wchar_t);
        size_t totalSize = sizeof(DROPFILES) + pathBytes + sizeof(wchar_t);

        HGLOBAL hGlob = GlobalAlloc(GHND | GMEM_SHARE, totalSize);
        if (!hGlob) return STG_E_MEDIUMFULL;

        auto* df = static_cast<DROPFILES*>(GlobalLock(hGlob));
        df->pFiles = sizeof(DROPFILES);
        df->pt.x = 0; df->pt.y = 0;
        df->fNC = FALSE;
        df->fWide = TRUE;  // Unicode paths

        auto* pathBuf = reinterpret_cast<wchar_t*>(
            reinterpret_cast<uint8_t*>(df) + sizeof(DROPFILES));
        wcscpy_s(pathBuf, m_filePath.size() + 1, m_filePath.c_str());

        GlobalUnlock(hGlob);

        pMed->tymed = TYMED_HGLOBAL;
        pMed->hGlobal = hGlob;
        return S_OK;
    }

    // CFSTR_PREFERREDDROPEFFECT
    CLIPFORMAT cfDropEffect = static_cast<CLIPFORMAT>(
        RegisterClipboardFormatW(L"Preferred DropEffect"));
    if (pFE->cfFormat == cfDropEffect && (pFE->tymed & TYMED_HGLOBAL)) {
        HGLOBAL hGlob = GlobalAlloc(GHND | GMEM_SHARE, sizeof(DWORD));
        if (!hGlob) return STG_E_MEDIUMFULL;

        auto* effect = static_cast<DWORD*>(GlobalLock(hGlob));
        *effect = DROPEFFECT_COPY;
        GlobalUnlock(hGlob);

        pMed->tymed = TYMED_HGLOBAL;
        pMed->hGlobal = hGlob;
        return S_OK;
    }

    // CFSTR_FILECONTENTS
    CLIPFORMAT cfFileContents = static_cast<CLIPFORMAT>(
        RegisterClipboardFormatW(L"FileContents"));
    if (pFE->cfFormat == cfFileContents && (pFE->tymed & TYMED_ISTREAM)) {
        auto* stream = new FileStream(m_filePath);
        pMed->tymed = TYMED_ISTREAM;
        pMed->pstm = stream;
        pMed->pUnkForRelease = stream;  // Released by caller
        return S_OK;
    }

    return DV_E_FORMATETC;
}

HRESULT FileDataObject::GetDataHere(FORMATETC*, STGMEDIUM*) {
    return E_NOTIMPL;
}

HRESULT FileDataObject::QueryGetData(FORMATETC* pFE) {
    if (!pFE) return E_INVALIDARG;

    for (auto& fmt : m_formats) {
        if (fmt.cfFormat == pFE->cfFormat &&
            (fmt.tymed & pFE->tymed)) {
            return S_OK;
        }
    }
    return DV_E_FORMATETC;
}

HRESULT FileDataObject::GetCanonicalFormatEtc(FORMATETC*, FORMATETC* pOut) {
    if (pOut) pOut->ptd = nullptr;
    return DATA_S_SAMEFORMATETC;
}

HRESULT FileDataObject::SetData(FORMATETC*, STGMEDIUM*, BOOL) {
    return E_NOTIMPL;
}

HRESULT FileDataObject::EnumFormatEtc(DWORD dwDirection,
                                       IEnumFORMATETC** ppEnum)
{
    if (!ppEnum) return E_INVALIDARG;
    *ppEnum = nullptr;
    if (dwDirection != DATADIR_GET)
        return E_NOTIMPL;

    // Simple enumerator that returns our three FORMATETCs.
    struct EnumFormatEtc final : public IEnumFORMATETC {
        LONG refCount{1};
        int index{};
        FORMATETC* formats;
        UINT count;

        EnumFormatEtc(FORMATETC* fmt, UINT c) : formats(fmt), count(c) {}

        ULONG AddRef() override { return InterlockedIncrement(&refCount); }
        ULONG Release() override {
            ULONG r = InterlockedDecrement(&refCount);
            if (r == 0) delete this; return r;
        }
        HRESULT QueryInterface(REFIID riid, void** ppv) override {
            if (!ppv) return E_INVALIDARG; *ppv = nullptr;
            if (riid == IID_IUnknown || riid == IID_IEnumFORMATETC) {
                *ppv = this; AddRef(); return S_OK;
            }
            return E_NOINTERFACE;
        }
        HRESULT Next(ULONG celt, FORMATETC* rgelt, ULONG* pceltFetched) override {
            ULONG fetched = 0;
            while (fetched < celt && index < static_cast<int>(count)) {
                rgelt[fetched] = formats[index++];
                fetched++;
            }
            if (pceltFetched) *pceltFetched = fetched;
            return fetched == celt ? S_OK : S_FALSE;
        }
        HRESULT Skip(ULONG celt) override {
            index += static_cast<int>(celt);
            return index >= static_cast<int>(count) ? S_FALSE : S_OK;
        }
        HRESULT Reset() override { index = 0; return S_OK; }
        HRESULT Clone(IEnumFORMATETC** ppOut) override {
            if (!ppOut) return E_INVALIDARG;
            auto* c = new EnumFormatEtc(formats, count);
            c->index = index;
            *ppOut = c;
            return S_OK;
        }
    };

    *ppEnum = new EnumFormatEtc(m_formats, kFormatCount);
    return S_OK;
}

HRESULT FileDataObject::DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) {
    return OLE_E_ADVISENOTSUPPORTED;
}
HRESULT FileDataObject::DUnadvise(DWORD) {
    return OLE_E_ADVISENOTSUPPORTED;
}
HRESULT FileDataObject::EnumDAdvise(IEnumSTATDATA**) {
    return OLE_E_ADVISENOTSUPPORTED;
}

// ══════════════════════════════════════════════════════════════════════════════
// FileStream (IStream implementation for CFSTR_FILECONTENTS)
// ══════════════════════════════════════════════════════════════════════════════

FileDataObject::FileStream::FileStream(const std::wstring& path)
    : m_storedPath(path)
{
    m_hFile = CreateFileW(
        path.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);

    if (m_hFile != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER size{};
        GetFileSizeEx(m_hFile, &size);
        m_fileSize = static_cast<uint64_t>(size.QuadPart);
    }
}

FileDataObject::FileStream::~FileStream() {
    if (m_hFile != INVALID_HANDLE_VALUE)
        CloseHandle(m_hFile);
}

ULONG FileDataObject::FileStream::AddRef() {
    return InterlockedIncrement(&m_refCount);
}
ULONG FileDataObject::FileStream::Release() {
    ULONG r = InterlockedDecrement(&m_refCount);
    if (r == 0) delete this;
    return r;
}

HRESULT FileDataObject::FileStream::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG; *ppv = nullptr;
    if (riid == IID_IUnknown || riid == IID_IStream) {
        *ppv = static_cast<IStream*>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
}

HRESULT FileDataObject::FileStream::Read(void* pv, ULONG cb, ULONG* pcbRead) {
    if (m_hFile == INVALID_HANDLE_VALUE)
        return STG_E_READFAULT;

    DWORD read = 0;
    if (!ReadFile(m_hFile, pv, cb, &read, nullptr))
        return STG_E_READFAULT;

    if (pcbRead) *pcbRead = read;
    m_position.QuadPart += read;
    return (read == cb) ? S_OK : S_FALSE;
}

HRESULT FileDataObject::FileStream::Write(const void*, ULONG, ULONG*) {
    return STG_E_ACCESSDENIED;  // Read-only stream
}

HRESULT FileDataObject::FileStream::Seek(
    LARGE_INTEGER dlibMove, DWORD dwOrigin, ULARGE_INTEGER* plibNewPos)
{
    if (m_hFile == INVALID_HANDLE_VALUE)
        return STG_E_READFAULT;

    DWORD moveMethod = FILE_BEGIN;
    if (dwOrigin == STREAM_SEEK_CUR) moveMethod = FILE_CURRENT;
    else if (dwOrigin == STREAM_SEEK_END) moveMethod = FILE_END;

    LARGE_INTEGER newPos{};
    if (!SetFilePointerEx(m_hFile, dlibMove, &newPos, moveMethod))
        return STG_E_READFAULT;

    m_position = newPos;
    if (plibNewPos) plibNewPos->QuadPart = newPos.QuadPart;
    return S_OK;
}

HRESULT FileDataObject::FileStream::SetSize(ULARGE_INTEGER) {
    return STG_E_ACCESSDENIED;
}
HRESULT FileDataObject::FileStream::CopyTo(
    IStream*, ULARGE_INTEGER, ULARGE_INTEGER*, ULARGE_INTEGER*)
{
    return E_NOTIMPL;
}
HRESULT FileDataObject::FileStream::Commit(DWORD) { return S_OK; }
HRESULT FileDataObject::FileStream::Revert() { return S_OK; }
HRESULT FileDataObject::FileStream::LockRegion(
    ULARGE_INTEGER, ULARGE_INTEGER, DWORD) { return STG_E_INVALIDFUNCTION; }
HRESULT FileDataObject::FileStream::UnlockRegion(
    ULARGE_INTEGER, ULARGE_INTEGER, DWORD) { return STG_E_INVALIDFUNCTION; }

HRESULT FileDataObject::FileStream::Stat(STATSTG* stat, DWORD grfStatFlag) {
    if (!stat) return E_INVALIDARG;
    ZeroMemory(stat, sizeof(*stat));
    stat->type = STGTY_STREAM;
    stat->cbSize.QuadPart = m_fileSize;
    stat->grfMode = STGM_READ | STGM_SHARE_DENY_NONE;

    if (!(grfStatFlag & STATFLAG_NONAME)) {
        // Provide a name (optional but good practice).
        std::wstring name = L"SolStreamFile";
        stat->pwcsName = static_cast<wchar_t*>(
            CoTaskMemAlloc((name.size() + 1) * sizeof(wchar_t)));
        if (stat->pwcsName)
            wcscpy_s(stat->pwcsName, name.size() + 1, name.c_str());
    }
    return S_OK;
}

HRESULT FileDataObject::FileStream::Clone(IStream** ppStream) {
    if (!ppStream) return E_INVALIDARG;
    auto* clone = new FileStream(m_hFile != INVALID_HANDLE_VALUE
        ? m_storedPath : L"");
    // Share the same file handle by duplicating.
    if (m_hFile != INVALID_HANDLE_VALUE) {
        HANDLE hDup = INVALID_HANDLE_VALUE;
        DuplicateHandle(GetCurrentProcess(), m_hFile,
                        GetCurrentProcess(), &hDup,
                        0, FALSE, DUPLICATE_SAME_ACCESS);
        clone->m_hFile = hDup;
    }
    *ppStream = clone;
    return S_OK;
}

} // namespace solstream::filetransfer
