#pragma once

#include <QList>
#include <QString>

namespace felix::core::windows {

struct AdapterInfo {
    QString name;
    QString description;
    QString interfaceGuid;
};

class NetworkAdapters {
public:
    [[nodiscard]] static QList<AdapterInfo> list(QString *error = nullptr);
    [[nodiscard]] static QString interfaceGuid(const QString &friendlyName);
    [[nodiscard]] static QString classRegistryPath(const QString &interfaceGuid);
};

}  // namespace felix::core::windows
