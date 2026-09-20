#include "felix/core/windows/system_facts.h"

#include <QDir>
#include <QFileInfo>
#include <QProcessEnvironment>
#include <QStringList>

#include <iterator>

#ifdef FELIX_PLATFORM_WINDOWS
#include <windows.h>
#include <tlhelp32.h>
#include <winioctl.h>
#endif

namespace felix::core::windows {

bool SystemFacts::isAdministrator()
{
#ifdef FELIX_PLATFORM_WINDOWS
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return false;
    }

    TOKEN_ELEVATION elevation{};
    DWORD size = sizeof(elevation);
    const BOOL queried = GetTokenInformation(
        token,
        TokenElevation,
        &elevation,
        sizeof(elevation),
        &size
    );
    CloseHandle(token);
    return queried && elevation.TokenIsElevated != 0;
#else
    return false;
#endif
}

bool SystemFacts::antiCheatExpertPresent()
{
#ifdef FELIX_PLATFORM_WINDOWS
    const QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    for (const QString &variable : {
             QStringLiteral("ProgramFiles"),
             QStringLiteral("ProgramFiles(x86)"),
             QStringLiteral("ProgramW6432"),
         }) {
        const QString root = environment.value(variable);
        if (!root.isEmpty()) {
            const QFileInfo path(QDir(root).filePath(QStringLiteral("AntiCheatExpert")));
            if (path.isDir()) {
                return true;
            }
        }
    }

    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return false;
    }

    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    bool found = false;
    if (Process32FirstW(snapshot, &entry)) {
        do {
            const QString name = QString::fromWCharArray(entry.szExeFile);
            if (
                name.compare(QStringLiteral("SGuard64.exe"), Qt::CaseInsensitive) == 0
                || name.compare(QStringLiteral("SGuardSvc64.exe"), Qt::CaseInsensitive) == 0
            ) {
                found = true;
                break;
            }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return found;
#else
    return false;
#endif
}

bool SystemFacts::hasSsd()
{
#ifdef FELIX_PLATFORM_WINDOWS
    wchar_t drives[512]{};
    const DWORD length = GetLogicalDriveStringsW(
        static_cast<DWORD>(std::size(drives)),
        drives
    );
    if (length == 0 || length >= std::size(drives)) {
        return false;
    }

    const wchar_t *current = drives;
    while (*current != L'\0') {
        const QString drive = QString::fromWCharArray(current);
        current += drive.size() + 1;

        if (GetDriveTypeW(reinterpret_cast<LPCWSTR>(drive.utf16())) != DRIVE_FIXED) {
            continue;
        }

        const QString volumePath = QStringLiteral("\\\\.\\%1").arg(drive.left(2));
        const HANDLE volume = CreateFileW(
            reinterpret_cast<LPCWSTR>(volumePath.utf16()),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            0,
            nullptr
        );
        if (volume == INVALID_HANDLE_VALUE) {
            continue;
        }

        STORAGE_PROPERTY_QUERY query{};
        query.PropertyId = StorageDeviceSeekPenaltyProperty;
        query.QueryType = PropertyStandardQuery;
        DEVICE_SEEK_PENALTY_DESCRIPTOR descriptor{};
        DWORD returned = 0;
        const BOOL success = DeviceIoControl(
            volume,
            IOCTL_STORAGE_QUERY_PROPERTY,
            &query,
            sizeof(query),
            &descriptor,
            sizeof(descriptor),
            &returned,
            nullptr
        );
        CloseHandle(volume);
        if (success && !descriptor.IncursSeekPenalty) {
            return true;
        }
    }
    return false;
#else
    return false;
#endif
}

bool SystemFacts::isSsdDetectionAvailable()
{
#ifdef FELIX_PLATFORM_WINDOWS
    return true;
#else
    return false;
#endif
}

}  // namespace felix::core::windows
