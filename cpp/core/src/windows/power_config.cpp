#include "felix/core/windows/power_config.h"

#include "felix/core/windows/process_runner.h"

#include <QRegularExpression>

#include <stdexcept>

namespace felix::core::windows {
namespace {

const QRegularExpression &schemePattern()
{
    static const QRegularExpression pattern(
        QStringLiteral(
            "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\s*(?:\\*\\s*)?(?:\\(([^)]*)\\))?"
        )
    );
    return pattern;
}

QList<PowerScheme> parseSchemes(const QString &output, const QString &activeGuid)
{
    QList<PowerScheme> schemes;
    auto iterator = schemePattern().globalMatch(output);
    while (iterator.hasNext()) {
        const QRegularExpressionMatch match = iterator.next();
        PowerScheme scheme;
        scheme.guid = match.captured(1).toLower();
        scheme.name = match.captured(2).trimmed();
        scheme.active = scheme.guid == activeGuid.toLower();
        schemes.append(scheme);
    }
    return schemes;
}

void ensureSuccess(const CommandResult &result, const QString &operation)
{
    if (!result.success()) {
        throw std::runtime_error(
            QStringLiteral("%1 failed. %2").arg(operation, result.combinedOutput())
                .toUtf8()
                .constData()
        );
    }
}

QString schemeSettingPath(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid
)
{
    return QStringLiteral(
               "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\"
               "%1\\%2\\%3"
    )
        .arg(schemeGuid, subgroupGuid, settingGuid);
}

QString defaultSettingPath(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid
)
{
    return QStringLiteral(
               "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\"
               "%1\\%2\\DefaultPowerSchemeValues\\%3"
    )
        .arg(subgroupGuid, settingGuid, schemeGuid);
}

QJsonObject valueSnapshot(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid,
    const QString &valueName,
    bool useDefaultFallback
)
{
    RegistryValue value = RegistryStore::read(
        schemeSettingPath(schemeGuid, subgroupGuid, settingGuid),
        valueName
    );
    if (!value.exists && useDefaultFallback) {
        value = RegistryStore::read(
            defaultSettingPath(schemeGuid, subgroupGuid, settingGuid),
            valueName
        );
    }
    return value.toJson();
}

}  // namespace

bool PowerConfig::executableAvailable()
{
    return !ProcessRunner::findExecutable(QStringLiteral("powercfg.exe")).isEmpty();
}

QList<PowerScheme> PowerConfig::listSchemes(QString *error)
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("powercfg.exe"),
        {QStringLiteral("/list")}
    );
    if (!result.success()) {
        if (error != nullptr) {
            *error = result.combinedOutput();
        }
        return {};
    }

    const PowerScheme active = activeScheme(error);
    return parseSchemes(result.standardOutput, active.guid);
}

PowerScheme PowerConfig::activeScheme(QString *error)
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("powercfg.exe"),
        {QStringLiteral("/getactivescheme")}
    );
    if (!result.success()) {
        if (error != nullptr) {
            *error = result.combinedOutput();
        }
        return {};
    }

    const QRegularExpressionMatch match = schemePattern().match(result.standardOutput);
    if (!match.hasMatch()) {
        if (error != nullptr) {
            *error = QStringLiteral("Unable to parse the active power scheme GUID.");
        }
        return {};
    }

    return PowerScheme{
        match.captured(1).toLower(),
        match.captured(2).trimmed(),
        true,
    };
}

QString PowerConfig::findSchemeGuidByName(const QString &name, QString *error)
{
    const QList<PowerScheme> schemes = listSchemes(error);
    for (const PowerScheme &scheme : schemes) {
        if (scheme.name.compare(name, Qt::CaseInsensitive) == 0) {
            return scheme.guid;
        }
    }
    return {};
}

void PowerConfig::setActive(const QString &guid)
{
    ensureSuccess(
        ProcessRunner::run(
            QStringLiteral("powercfg.exe"),
            {QStringLiteral("/setactive"), guid}
        ),
        QStringLiteral("powercfg /setactive")
    );
}

QString PowerConfig::duplicateScheme(const QString &sourceGuid)
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("powercfg.exe"),
        {QStringLiteral("/duplicatescheme"), sourceGuid}
    );
    ensureSuccess(result, QStringLiteral("powercfg /duplicatescheme"));

    const QRegularExpressionMatch match = schemePattern().match(result.standardOutput);
    if (!match.hasMatch()) {
        throw std::runtime_error("Unable to parse the duplicated power scheme GUID.");
    }
    return match.captured(1).toLower();
}

void PowerConfig::renameScheme(const QString &guid, const QString &name)
{
    ensureSuccess(
        ProcessRunner::run(
            QStringLiteral("powercfg.exe"),
            {QStringLiteral("/changename"), guid, name}
        ),
        QStringLiteral("powercfg /changename")
    );
}

void PowerConfig::deleteScheme(const QString &guid)
{
    ensureSuccess(
        ProcessRunner::run(
            QStringLiteral("powercfg.exe"),
            {QStringLiteral("/delete"), guid}
        ),
        QStringLiteral("powercfg /delete")
    );
}

void PowerConfig::setAcValueIndex(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid,
    int value
)
{
    ensureSuccess(
        ProcessRunner::run(
            QStringLiteral("powercfg.exe"),
            {
                QStringLiteral("/setacvalueindex"),
                schemeGuid,
                subgroupGuid,
                settingGuid,
                QString::number(value),
            }
        ),
        QStringLiteral("powercfg /setacvalueindex")
    );
    setActive(schemeGuid);
}

void PowerConfig::setDcValueIndex(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid,
    int value
)
{
    ensureSuccess(
        ProcessRunner::run(
            QStringLiteral("powercfg.exe"),
            {
                QStringLiteral("/setdcvalueindex"),
                schemeGuid,
                subgroupGuid,
                settingGuid,
                QString::number(value),
            }
        ),
        QStringLiteral("powercfg /setdcvalueindex")
    );
    setActive(schemeGuid);
}

QJsonObject PowerConfig::settingValueSnapshot(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid,
    bool useDefaultFallback
)
{
    return QJsonObject{
        {
            QStringLiteral("ac"),
            valueSnapshot(
                schemeGuid,
                subgroupGuid,
                settingGuid,
                QStringLiteral("ACSettingIndex"),
                useDefaultFallback
            ),
        },
        {
            QStringLiteral("dc"),
            valueSnapshot(
                schemeGuid,
                subgroupGuid,
                settingGuid,
                QStringLiteral("DCSettingIndex"),
                useDefaultFallback
            ),
        },
    };
}

PowerSettingSpec PowerConfig::settingSpec(const QString &name)
{
    if (name == QStringLiteral("Processor")) {
        return {
            name,
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("893dee8e-2bef-41e0-89c6-b55d0929964c"),
            QStringLiteral("Processor minimum state"),
        };
    }
    if (name == QStringLiteral("CoreParking")) {
        return {
            name,
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("0cc5b647-c1df-4637-891a-dec35c318583"),
            QStringLiteral("Processor core parking minimum cores"),
        };
    }
    if (name == QStringLiteral("CpuIdle")) {
        return {
            name,
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("5d76a2ca-e8c0-402f-a133-2158492d58ad"),
            QStringLiteral("Processor idle disable"),
        };
    }
    if (name == QStringLiteral("Usb")) {
        return {
            name,
            QStringLiteral("2a737441-1930-4402-8d77-b2bebba308a3"),
            QStringLiteral("48e6b7a6-50f5-4782-a5d4-53bb8f07e226"),
            QStringLiteral("USB selective suspend"),
        };
    }
    if (name == QStringLiteral("Pcie")) {
        return {
            name,
            QStringLiteral("501a4d13-42af-4429-9fd1-a8218c268e20"),
            QStringLiteral("ee12f906-d277-404b-b6da-e5fa1a576df5"),
            QStringLiteral("PCI Express link state power management"),
        };
    }
    throw std::runtime_error("Unknown power setting definition.");
}

}  // namespace felix::core::windows
