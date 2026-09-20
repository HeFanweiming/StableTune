#include "felix/core/windows/network_adapters.h"

#include "felix/core/windows/registry.h"

#include <QByteArray>

#ifdef FELIX_PLATFORM_WINDOWS
#include <winsock2.h>
#include <iphlpapi.h>
#include <windows.h>
#endif

namespace felix::core::windows {
namespace {

QString normalizeGuid(const QString &guid)
{
    QString value = guid.trimmed();
    if (value.startsWith(QLatin1Char('{'))) {
        value.remove(0, 1);
    }
    if (value.endsWith(QLatin1Char('}'))) {
        value.chop(1);
    }
    return value.toUpper();
}

}  // namespace

QString NetworkAdapters::interfaceGuid(const QString &friendlyName)
{
    for (const AdapterInfo &adapter : list()) {
        if (adapter.name.compare(friendlyName, Qt::CaseInsensitive) == 0) {
            return adapter.interfaceGuid;
        }
    }
    return {};
}

QList<AdapterInfo> NetworkAdapters::list(QString *error)
{
    QList<AdapterInfo> adapters;
#ifdef FELIX_PLATFORM_WINDOWS
    ULONG size = 16 * 1024;
    QByteArray buffer(static_cast<int>(size), Qt::Uninitialized);
    ULONG status = GetAdaptersAddresses(
        AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr,
        reinterpret_cast<IP_ADAPTER_ADDRESSES *>(buffer.data()),
        &size
    );
    if (status == ERROR_BUFFER_OVERFLOW) {
        buffer.resize(static_cast<int>(size));
        status = GetAdaptersAddresses(
            AF_UNSPEC,
            GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            nullptr,
            reinterpret_cast<IP_ADAPTER_ADDRESSES *>(buffer.data()),
            &size
        );
    }
    if (status != NO_ERROR) {
        if (error != nullptr) {
            *error = QStringLiteral("GetAdaptersAddresses failed with status %1.")
                         .arg(status);
        }
        return adapters;
    }

    for (
        auto *adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES *>(buffer.data());
        adapter != nullptr;
        adapter = adapter->Next
    ) {
        const QString adapterFriendlyName = QString::fromWCharArray(adapter->FriendlyName);
        if (!adapterFriendlyName.isEmpty()) {
            adapters.append(
                AdapterInfo{
                    adapterFriendlyName,
                    QString::fromWCharArray(adapter->Description),
                    QString::fromLatin1(adapter->AdapterName).toUpper(),
                }
            );
        }
    }
#else
    if (error != nullptr) {
        *error = QStringLiteral("Network adapter enumeration requires Windows.");
    }
#endif
    return adapters;
}

QString NetworkAdapters::classRegistryPath(const QString &interfaceGuid)
{
    const QString classRoot = QStringLiteral(
        "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\"
        "{4d36e972-e325-11ce-bfc1-08002be10318}"
    );
    const QString expected = normalizeGuid(interfaceGuid);
    for (const QString &subKey : RegistryStore::subKeys(classRoot)) {
        const QString candidate = classRoot + QLatin1Char('\\') + subKey;
        const RegistryValue instance = RegistryStore::read(
            candidate,
            QStringLiteral("NetCfgInstanceId")
        );
        if (
            instance.exists
            && normalizeGuid(instance.value.toString()) == expected
        ) {
            return candidate;
        }
    }
    return {};
}

}  // namespace felix::core::windows
