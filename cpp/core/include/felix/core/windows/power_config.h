#pragma once

#include "felix/core/windows/registry.h"

#include <QJsonObject>
#include <QList>
#include <QString>

namespace felix::core::windows {

struct PowerScheme {
    QString guid;
    QString name;
    bool active = false;
};

struct PowerSettingSpec {
    QString name;
    QString subgroupGuid;
    QString settingGuid;
    QString label;
};

class PowerConfig {
public:
    [[nodiscard]] static bool executableAvailable();
    [[nodiscard]] static QList<PowerScheme> listSchemes(QString *error = nullptr);
    [[nodiscard]] static PowerScheme activeScheme(QString *error = nullptr);
    [[nodiscard]] static QString findSchemeGuidByName(
        const QString &name,
        QString *error = nullptr
    );

    static void setActive(const QString &guid);
    static QString duplicateScheme(const QString &sourceGuid);
    static void renameScheme(const QString &guid, const QString &name);
    static void deleteScheme(const QString &guid);
    static void setAcValueIndex(
        const QString &schemeGuid,
        const QString &subgroupGuid,
        const QString &settingGuid,
        int value
    );
    static void setDcValueIndex(
        const QString &schemeGuid,
        const QString &subgroupGuid,
        const QString &settingGuid,
        int value
    );

    [[nodiscard]] static QJsonObject settingValueSnapshot(
        const QString &schemeGuid,
        const QString &subgroupGuid,
        const QString &settingGuid,
        bool useDefaultFallback = false
    );

    [[nodiscard]] static PowerSettingSpec settingSpec(const QString &name);
};

}  // namespace felix::core::windows

