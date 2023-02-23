#include "wimg.hpp"

#include <wimgapi.h>

#include <codecvt>

class WString
{
    WString(const WString&) = delete;
    WString& operator=(const WString&) = delete;

public:
    WString(const char* utf8str)
    {
        // Convert from utf8 -> wchar_t*
        using utf8_to_wchar_t = std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>, wchar_t>;

        utf8_to_wchar_t wchar_t_converter;
        m_str = wchar_t_converter.from_bytes(utf8str);
    }

    const wchar_t* c_str() const
    {
        return m_str.c_str();
    }

private:
    std::wstring m_str;
};

class WIMHandlePtr
{
public:
    explicit WIMHandlePtr(HANDLE handle) : m_handle(handle)
    {
    }

    WIMHandlePtr(const WIMHandlePtr&) = delete;
    WIMHandlePtr& operator=(const WIMHandlePtr&) = delete;

    ~WIMHandlePtr()
    {
        if (!is_null())
        {
            WIMCloseHandle(m_handle);
        }
    }

    HANDLE get() const
    {
        return m_handle;
    }

    bool is_null() const
    {
        return get() == nullptr;
    }

private:
    HANDLE m_handle;
};

static INT_PTR CALLBACK WIMOperationCallback(DWORD messageID, WPARAM wParam, LPARAM lParam, void* pvUserData)
{
    UNREFERENCED_PARAMETER(lParam);
    UNREFERENCED_PARAMETER(pvUserData);

    if (messageID == WIM_MSG_PROGRESS)
    {
        const UINT percent = static_cast<UINT>(wParam);
        if ((percent % 5) == 0)
        {
            // std::cout << "[WIM] " << percent << "%" << std::endl;
        }
    }

#if 0
    else if (messageID == WIM_MSG_QUERY_ABORT)
    {
        // return this if operation should be cancelled.
        return WIM_MSG_ABORT_IMAGE;
    }
#endif

    return WIM_MSG_SUCCESS;
}

HRESULT ApplyImage(const char* source, const char* dest, const char* temp /*= nullptr*/)
{
    WString wimPath{ source };
    WString applyPath{ dest };

    const DWORD access = WIM_GENERIC_READ | WIM_GENERIC_MOUNT;
    const DWORD mode = WIM_OPEN_EXISTING;
    const DWORD flags = 0;
    const DWORD comp = WIM_COMPRESS_NONE;

    WIMHandlePtr wimFile(WIMCreateFile(wimPath.c_str(), access, mode, flags, comp, nullptr));
    if (wimFile.is_null())
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    if (temp != nullptr)
    {
        WString tempPath{ temp };
        if (!WIMSetTemporaryPath(wimFile.get(), tempPath.c_str()))
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }
    }

    if (WIMRegisterMessageCallback(wimFile.get(), reinterpret_cast<FARPROC>(WIMOperationCallback), nullptr /*token*/)
        == INVALID_CALLBACK_VALUE)
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    const DWORD index = 1;
    WIMHandlePtr wimImage(WIMLoadImage(wimFile.get(), index));
    if (wimImage.is_null())
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    // WIMApplyImage requires elevation.
    if (!WIMApplyImage(wimImage.get(), applyPath.c_str(), 0 /*flags*/))
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    WIMUnregisterMessageCallback(wimImage.get(), reinterpret_cast<FARPROC>(WIMOperationCallback));

    return S_OK;
}