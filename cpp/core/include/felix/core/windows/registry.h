#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVariant>

namespace felix::core::windows {

struct RegistryValue {
    bool exists = false;
    QString kind;
    QVariant value;
    QJsonObject toJson() const;
    static RegistryValue fromJson(const QJsonObject &object);
};

class RegistryStore {
public:
    static RegistryValue read(const QString &path, const QString &name);
    static void write(const QString &path, const QString &name, const QString &kind, const QVariant &value);
    static void remove(const QString &path, const QString &name, bool ignoreMissing = true);
    static bool keyExists(const QString &path);
    static QStringList subKeys(const QString &path);

    static bool equivalent(const RegistryValue &left, const RegistryValue &right);
};

QString normalizeRegistryPath(const QString &path);
QString registryValueComparable(const RegistryValue &value);

}  // namespace felix::core::windows

