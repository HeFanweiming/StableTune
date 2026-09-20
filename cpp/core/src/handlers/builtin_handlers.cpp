#include "felix/core/handler_registry.h"

#include "felix/core/windows/network_adapters.h"
#include "felix/core/windows/power_config.h"
#include "felix/core/windows/process_runner.h"
#include "felix/core/windows/registry.h"
#include "felix/core/windows/system_facts.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonValue>
#include <QRegularExpression>
#include <QSet>

#ifdef FELIX_PLATFORM_WINDOWS
#include <windows.h>
#endif

#include <algorithm>
#include <stdexcept>

namespace felix::core {
namespace {

using windows::CommandResult;
using windows::NetworkAdapters;
using windows::PowerConfig;
using windows::PowerScheme;
using windows::ProcessRunner;
using windows::RegistryStore;
using windows::RegistryValue;
using windows::SystemFacts;

[[noreturn]] void fail(const QString &message)
{
    throw std::runtime_error(message.toUtf8().constData());
}

QString resolveTemplate(
    const QString &text,
    const QHash<QString, QString> &values
)
{
    static const QRegularExpression tokenPattern(
        QStringLiteral("\\{([A-Za-z0-9_]+)\\}")
    );
    QString result = text;
    auto iterator = tokenPattern.globalMatch(text);
    while (iterator.hasNext()) {
        const QRegularExpressionMatch match = iterator.next();
        const QString key = match.captured(1);
        if (!values.contains(key)) {
            fail(QStringLiteral("Unresolved template value '%1' in '%2'.")
                     .arg(key, text));
        }
        result.replace(match.captured(0), values.value(key));
    }
    return result;
}

QJsonArray resolveRegistryChanges(
    const QJsonArray &changes,
    const RuleOptions &options
)
{
    const QHash<QString, QString> values = options.templateValues();
    QJsonArray resolved;
    for (const QJsonValue &entry : changes) {
        const QJsonObject change = entry.toObject();
        QJsonObject output = change;
        output.insert(
            QStringLiteral("path"),
            resolveTemplate(change.value(QStringLiteral("path")).toString(), values)
        );
        output.insert(
            QStringLiteral("name"),
            resolveTemplate(change.value(QStringLiteral("name")).toString(), values)
        );
        if (change.value(QStringLiteral("value")).isString()) {
            output.insert(
                QStringLiteral("value"),
                resolveTemplate(change.value(QStringLiteral("value")).toString(), values)
            );
        }
        resolved.append(output);
    }
    return resolved;
}

RegistryValue registryValueFromJson(const QJsonValue &value)
{
    return RegistryValue::fromJson(value.toObject());
}

QJsonArray readRegistryEntries(const QJsonArray &targets)
{
    QJsonArray entries;
    for (const QJsonValue &targetValue : targets) {
        const QJsonObject target = targetValue.toObject();
        entries.append(
            RegistryStore::read(
                target.value(QStringLiteral("path")).toString(),
                target.value(QStringLiteral("name")).toString()
            ).toJson()
        );
    }
    return entries;
}

QVariant registryTargetVariant(const QJsonValue &value, const QString &kind)
{
    if (kind == QStringLiteral("DWord")) {
        if (value.isString()) {
            return value.toString().toUInt();
        }
        return static_cast<quint32>(value.toDouble());
    }
    if (kind == QStringLiteral("QWord")) {
        if (value.isString()) {
            return QVariant::fromValue<qulonglong>(value.toString().toULongLong());
        }
        return QVariant::fromValue<qulonglong>(
            static_cast<qulonglong>(value.toDouble())
        );
    }
    if (kind == QStringLiteral("Binary")) {
        if (value.isString()) {
            return QByteArray::fromBase64(value.toString().toLatin1());
        }
        return QByteArray();
    }
    if (kind == QStringLiteral("MultiString")) {
        QStringList values;
        for (const QJsonValue &entry : value.toArray()) {
            values.append(entry.toString());
        }
        return values;
    }
    return value.toString();
}

void writeRegistryEntry(const QJsonObject &entry)
{
    RegistryStore::write(
        entry.value(QStringLiteral("path")).toString(),
        entry.value(QStringLiteral("name")).toString(),
        entry.value(QStringLiteral("kind")).toString(),
        registryTargetVariant(
            entry.value(QStringLiteral("value")),
            entry.value(QStringLiteral("kind")).toString()
        )
    );
}

void restoreRegistryEntry(const RegistryValue &value, const QString &path, const QString &name)
{
    if (!value.exists) {
        RegistryStore::remove(path, name);
        return;
    }
    RegistryStore::write(path, name, value.kind, value.value);
}

bool registryEntriesCurrent(const QJsonArray &entries)
{
    for (const QJsonValue &entryValue : entries) {
        const QJsonObject entry = entryValue.toObject();
        const RegistryValue expected = RegistryValue::fromJson(entry);
        const RegistryValue current = RegistryStore::read(
            entry.value(QStringLiteral("path")).toString(),
            entry.value(QStringLiteral("name")).toString()
        );
        if (!RegistryStore::equivalent(expected, current)) {
            return false;
        }
    }
    return true;
}

QString ruleValue(const RuleDefinition &rule, const QString &key, const QString &fallback = {})
{
    const QJsonValue value = rule.raw.value(key);
    return value.isString() ? value.toString() : fallback;
}

int ruleIntValue(const RuleDefinition &rule, const QString &key, int fallback = 0)
{
    return rule.raw.value(key).toInt(fallback);
}

bool ruleBoolValue(const RuleDefinition &rule, const QString &key, bool fallback = false)
{
    return rule.raw.value(key).toBool(fallback);
}

QJsonObject powerSettingAfter(
    const QString &schemeGuid,
    const QString &subgroupGuid,
    const QString &settingGuid,
    int expectedAcValue
)
{
    const QJsonObject values = PowerConfig::settingValueSnapshot(
        schemeGuid,
        subgroupGuid,
        settingGuid
    );
    return QJsonObject{
        {QStringLiteral("schemeGuid"), schemeGuid},
        {QStringLiteral("subgroupGuid"), subgroupGuid},
        {QStringLiteral("settingGuid"), settingGuid},
        {QStringLiteral("expectedAcValue"), expectedAcValue},
        {QStringLiteral("ac"), values.value(QStringLiteral("ac"))},
        {QStringLiteral("dc"), values.value(QStringLiteral("dc"))},
    };
}

class BaseHandler : public IRuleHandler {
public:
    explicit BaseHandler(QString handlerId)
        : m_id(std::move(handlerId))
    {
    }

    QString id() const override
    {
        return m_id;
    }

protected:
    QString m_id;
};

class RegistrySetHandler : public BaseHandler {
public:
    explicit RegistrySetHandler(QString handlerId = QStringLiteral("RegistrySet"))
        : BaseHandler(std::move(handlerId))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(context);
        const QJsonArray changes = registryChanges(rule, options);
        if (changes.isEmpty()) {
            return Requirement::unavailable(QStringLiteral("No registry changes are defined."));
        }

        const QString prerequisiteKind = ruleValue(rule, QStringLiteral("prerequisiteKind"));
        if (prerequisiteKind == QStringLiteral("Ssd")) {
            if (!SystemFacts::isSsdDetectionAvailable() || !SystemFacts::hasSsd()) {
                return Requirement::unavailable(
                    QStringLiteral("No SSD or NVMe device was detected.")
                );
            }
        }
        if (
            prerequisiteKind == QStringLiteral("AntiCheatExpert")
            && !SystemFacts::antiCheatExpertPresent()
        ) {
            return Requirement::unavailable(
                QStringLiteral("Tencent AntiCheatExpert was not detected.")
            );
        }

        const QString inputKind = ruleValue(rule, QStringLiteral("inputKind"));
        if (inputKind == QStringLiteral("NetworkAdapter")) {
            if (
                options.stringValue(QStringLiteral("InterfaceAlias")).isEmpty()
                || options.stringValue(QStringLiteral("InterfaceGuid")).isEmpty()
            ) {
                return Requirement::unavailable(
                    QStringLiteral("InterfaceAlias and InterfaceGuid are required.")
                );
            }
        } else if (
            inputKind == QStringLiteral("ExecutablePath")
            || inputKind == QStringLiteral("ExecutablePriority")
        ) {
            const QFileInfo executable(options.stringValue(QStringLiteral("ExecutablePath")));
            if (!executable.isFile() || executable.suffix().compare(
                    QStringLiteral("exe"),
                    Qt::CaseInsensitive
                ) != 0) {
                return Requirement::unavailable(
                    QStringLiteral("A valid executable path is required.")
                );
            }
            if (
                inputKind == QStringLiteral("ExecutablePriority")
                && options.intValue(QStringLiteral("CpuPriorityClass")) != 2
                && options.intValue(QStringLiteral("CpuPriorityClass")) != 6
            ) {
                return Requirement::unavailable(
                    QStringLiteral("CPU priority must be Normal (2) or Above Normal (6).")
                );
            }
        }

        try {
            resolveRegistryChanges(changes, options);
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
        return Requirement::available(
            QStringLiteral("The registry target is available and the required input is valid.")
        );
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(context);
        return QJsonObject{
            {
                QStringLiteral("entries"),
                readRegistryEntries(resolveRegistryChanges(registryChanges(rule, options), options)),
            },
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(before);
        Q_UNUSED(context);
        const QJsonArray changes = resolveRegistryChanges(registryChanges(rule, options), options);
        for (const QJsonValue &change : changes) {
            writeRegistryEntry(change.toObject());
        }
        return QJsonObject{{QStringLiteral("entries"), readRegistryEntries(changes)}};
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return registryEntriesCurrent(
            snapshot.value(QStringLiteral("after")).toObject()
                .value(QStringLiteral("entries")).toArray()
        );
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return registryEntriesCurrent(
            snapshot.value(QStringLiteral("before")).toObject()
                .value(QStringLiteral("entries")).toArray()
        ) || registryEntriesCurrent(
            snapshot.value(QStringLiteral("after")).toObject()
                .value(QStringLiteral("entries")).toArray()
        );
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        for (
            const QJsonValue &entryValue :
            snapshot.value(QStringLiteral("before")).toObject()
                .value(QStringLiteral("entries")).toArray()
        ) {
            const RegistryValue value = registryValueFromJson(entryValue);
            restoreRegistryEntry(
                value,
                entryValue.toObject().value(QStringLiteral("path")).toString(),
                entryValue.toObject().value(QStringLiteral("name")).toString()
            );
        }
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return registryEntriesCurrent(
            snapshot.value(QStringLiteral("before")).toObject()
                .value(QStringLiteral("entries")).toArray()
        );
    }

protected:
    virtual QJsonArray registryChanges(
        const RuleDefinition &rule,
        const RuleOptions &options
    ) const
    {
        Q_UNUSED(options);
        return rule.raw.value(QStringLiteral("registryChanges")).toArray();
    }
};

class SyntheticRegistrySetHandler final : public RegistrySetHandler {
public:
    SyntheticRegistrySetHandler(QString handlerId, QJsonArray changes)
        : RegistrySetHandler(std::move(handlerId))
        , m_changes(std::move(changes))
    {
    }

protected:
    QJsonArray registryChanges(
        const RuleDefinition &rule,
        const RuleOptions &options
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        return m_changes;
    }

private:
    QJsonArray m_changes;
};

class PowerPlanHandler final : public BaseHandler {
public:
    PowerPlanHandler()
        : BaseHandler(QStringLiteral("PowerPlan"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        if (!PowerConfig::executableAvailable()) {
            return Requirement::unavailable(QStringLiteral("powercfg.exe is unavailable."));
        }
        QString error;
        const PowerScheme active = PowerConfig::activeScheme(&error);
        return active.guid.isEmpty()
            ? Requirement::unavailable(error.isEmpty() ? QStringLiteral("Active power scheme is unavailable.") : error)
            : Requirement::available(QStringLiteral("Active power scheme is readable."));
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        QString error;
        const PowerScheme active = PowerConfig::activeScheme(&error);
        if (active.guid.isEmpty()) {
            fail(error);
        }
        return QJsonObject{
            {QStringLiteral("activeGuid"), active.guid},
            {QStringLiteral("activeName"), active.name},
            {
                QStringLiteral("existingGuid"),
                PowerConfig::findSchemeGuidByName(QStringLiteral("StableTune Low Latency")),
            },
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        bool created = false;
        QString targetGuid = before.value(QStringLiteral("existingGuid")).toString();
        if (targetGuid.isEmpty()) {
            targetGuid = PowerConfig::duplicateScheme(
                before.value(QStringLiteral("activeGuid")).toString()
            );
            PowerConfig::renameScheme(targetGuid, QStringLiteral("StableTune Low Latency"));
            created = true;
        }
        PowerConfig::setActive(targetGuid);
        return QJsonObject{
            {QStringLiteral("targetGuid"), targetGuid},
            {QStringLiteral("created"), created},
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return PowerConfig::activeScheme().guid
            == snapshot.value(QStringLiteral("after")).toObject()
                   .value(QStringLiteral("targetGuid")).toString();
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString current = PowerConfig::activeScheme().guid;
        return current == snapshot.value(QStringLiteral("before")).toObject()
                             .value(QStringLiteral("activeGuid")).toString()
            || current == snapshot.value(QStringLiteral("after")).toObject()
                             .value(QStringLiteral("targetGuid")).toString();
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        PowerConfig::setActive(before.value(QStringLiteral("activeGuid")).toString());

        const QString targetGuid = after.value(QStringLiteral("targetGuid")).toString();
        if (
            after.value(QStringLiteral("created")).toBool()
            && !targetGuid.isEmpty()
            && PowerConfig::findSchemeGuidByName(QStringLiteral("StableTune Low Latency")) == targetGuid
        ) {
            PowerConfig::deleteScheme(targetGuid);
        }
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return PowerConfig::activeScheme().guid
            == snapshot.value(QStringLiteral("before")).toObject()
                   .value(QStringLiteral("activeGuid")).toString();
    }
};

class PowerSettingHandler final : public BaseHandler {
public:
    PowerSettingHandler(QString handlerId, QString settingName, int targetValue)
        : BaseHandler(std::move(handlerId))
        , m_settingName(std::move(settingName))
        , m_targetValue(targetValue)
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        if (!PowerConfig::executableAvailable()) {
            return Requirement::unavailable(QStringLiteral("powercfg.exe is unavailable."));
        }
        QString error;
        const PowerScheme active = PowerConfig::activeScheme(&error);
        if (active.guid.isEmpty()) {
            return Requirement::unavailable(error);
        }
        try {
            const windows::PowerSettingSpec spec = PowerConfig::settingSpec(m_settingName);
            const QJsonObject state = PowerConfig::settingValueSnapshot(
                active.guid,
                spec.subgroupGuid,
                spec.settingGuid
            );
            if (
                !state.value(QStringLiteral("ac")).toObject()
                     .value(QStringLiteral("exists")).toBool()
            ) {
                return Requirement::unavailable(
                    QStringLiteral("%1 is not available in the active scheme.").arg(spec.label)
                );
            }
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
        return Requirement::available(QStringLiteral("Power setting is available."));
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        QString error;
        const PowerScheme active = PowerConfig::activeScheme(&error);
        if (active.guid.isEmpty()) {
            fail(error);
        }
        const windows::PowerSettingSpec spec = PowerConfig::settingSpec(m_settingName);
        const QJsonObject values = PowerConfig::settingValueSnapshot(
            active.guid,
            spec.subgroupGuid,
            spec.settingGuid
        );
        return QJsonObject{
            {QStringLiteral("schemeGuid"), active.guid},
            {QStringLiteral("subgroupGuid"), spec.subgroupGuid},
            {QStringLiteral("settingGuid"), spec.settingGuid},
            {QStringLiteral("label"), spec.label},
            {QStringLiteral("ac"), values.value(QStringLiteral("ac"))},
            {QStringLiteral("dc"), values.value(QStringLiteral("dc"))},
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString schemeGuid = before.value(QStringLiteral("schemeGuid")).toString();
        const QString subgroupGuid = before.value(QStringLiteral("subgroupGuid")).toString();
        const QString settingGuid = before.value(QStringLiteral("settingGuid")).toString();
        PowerConfig::setAcValueIndex(
            schemeGuid,
            subgroupGuid,
            settingGuid,
            m_targetValue
        );
        return powerSettingAfter(
            schemeGuid,
            subgroupGuid,
            settingGuid,
            m_targetValue
        );
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const RegistryValue current = RegistryStore::read(
            QStringLiteral(
                "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\"
                "%1\\%2\\%3"
            )
                .arg(
                    before.value(QStringLiteral("schemeGuid")).toString(),
                    before.value(QStringLiteral("subgroupGuid")).toString(),
                    before.value(QStringLiteral("settingGuid")).toString()
                ),
            QStringLiteral("ACSettingIndex")
        );
        return current.exists
            && current.value.toInt()
                == after.value(QStringLiteral("expectedAcValue")).toInt();
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const RegistryValue current = RegistryStore::read(
            QStringLiteral(
                "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\"
                "%1\\%2\\%3"
            )
                .arg(
                    before.value(QStringLiteral("schemeGuid")).toString(),
                    before.value(QStringLiteral("subgroupGuid")).toString(),
                    before.value(QStringLiteral("settingGuid")).toString()
                ),
            QStringLiteral("ACSettingIndex")
        );
        return RegistryStore::equivalent(
            current,
            RegistryValue::fromJson(before.value(QStringLiteral("ac")).toObject())
        ) || RegistryStore::equivalent(
            current,
            RegistryValue::fromJson(after.value(QStringLiteral("ac")).toObject())
        );
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString path = QStringLiteral(
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\"
            "%1\\%2\\%3"
        ).arg(
            before.value(QStringLiteral("schemeGuid")).toString(),
            before.value(QStringLiteral("subgroupGuid")).toString(),
            before.value(QStringLiteral("settingGuid")).toString()
        );
        const RegistryValue ac = RegistryValue::fromJson(
            before.value(QStringLiteral("ac")).toObject()
        );
        const RegistryValue dc = RegistryValue::fromJson(
            before.value(QStringLiteral("dc")).toObject()
        );
        restoreRegistryEntry(ac, path, QStringLiteral("ACSettingIndex"));
        restoreRegistryEntry(dc, path, QStringLiteral("DCSettingIndex"));
        PowerConfig::setActive(before.value(QStringLiteral("schemeGuid")).toString());
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString path = QStringLiteral(
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\"
            "%1\\%2\\%3"
        ).arg(
            before.value(QStringLiteral("schemeGuid")).toString(),
            before.value(QStringLiteral("subgroupGuid")).toString(),
            before.value(QStringLiteral("settingGuid")).toString()
        );
        return RegistryStore::equivalent(
            RegistryStore::read(path, QStringLiteral("ACSettingIndex")),
            RegistryValue::fromJson(before.value(QStringLiteral("ac")).toObject())
        ) && RegistryStore::equivalent(
            RegistryStore::read(path, QStringLiteral("DCSettingIndex")),
            RegistryValue::fromJson(before.value(QStringLiteral("dc")).toObject())
        );
    }

private:
    QString m_settingName;
    int m_targetValue = 0;
};

struct HeterogeneousDefinition {
    QString name;
    QString label;
    QString subgroupGuid;
    QString settingGuid;
};

QList<HeterogeneousDefinition> heterogeneousDefinitions()
{
    return {
        {
            QStringLiteral("HETEROPOLICY"),
            QStringLiteral("生效的异类策略"),
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("7f2f5cfa-f10c-4823-b5e1-e93ae85f46b5"),
        },
        {
            QStringLiteral("SCHEDPOLICY"),
            QStringLiteral("异类线程调度策略"),
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("93b8b6dc-0698-4d1c-9ee4-0644e900c85d"),
        },
        {
            QStringLiteral("SHORTSCHEDPOLICY"),
            QStringLiteral("异类短运行线程调度策略"),
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("bae08b81-2d5e-4688-ad6a-13243356654b"),
        },
        {
            QStringLiteral("PERFBOOSTMODE"),
            QStringLiteral("处理器性能提升模式"),
            QStringLiteral("54533251-82be-4824-96c1-47b60b740d00"),
            QStringLiteral("be337238-0d82-4146-a960-4f3749d470c7"),
        },
    };
}

QJsonObject heterogeneousBaseline()
{
    const QList<PowerScheme> schemes = PowerConfig::listSchemes();
    const QList<QPair<QString, QString>> candidates{
        {
            QStringLiteral("8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"),
            QStringLiteral("Windows 内置高性能方案"),
        },
        {
            QStringLiteral("381b4222-f694-41f0-9685-ff5bb260df2e"),
            QStringLiteral("Windows 内置平衡方案"),
        },
    };

    for (const auto &candidate : candidates) {
        const bool exists = std::any_of(
            schemes.cbegin(),
            schemes.cend(),
            [&candidate](const PowerScheme &scheme) {
                return scheme.guid.compare(candidate.first, Qt::CaseInsensitive) == 0;
            }
        );
        if (!exists) {
            continue;
        }

        QJsonArray settings;
        bool complete = true;
        const QList<HeterogeneousDefinition> definitions = heterogeneousDefinitions();
        for (const HeterogeneousDefinition &definition : definitions) {
            const RegistryValue ac = RegistryValue::fromJson(
                PowerConfig::settingValueSnapshot(
                    candidate.first,
                    definition.subgroupGuid,
                    definition.settingGuid,
                    true
                ).value(QStringLiteral("ac")).toObject()
            );
            const RegistryValue dc = RegistryValue::fromJson(
                PowerConfig::settingValueSnapshot(
                    candidate.first,
                    definition.subgroupGuid,
                    definition.settingGuid,
                    true
                ).value(QStringLiteral("dc")).toObject()
            );
            if (!ac.exists || !dc.exists) {
                complete = false;
                break;
            }
            settings.append(QJsonObject{
                {QStringLiteral("name"), definition.name},
                {QStringLiteral("label"), definition.label},
                {QStringLiteral("subgroupGuid"), definition.subgroupGuid},
                {QStringLiteral("settingGuid"), definition.settingGuid},
                {QStringLiteral("targetAc"), ac.value.toInt()},
                {QStringLiteral("targetDc"), dc.value.toInt()},
            });
        }

        if (complete) {
            return QJsonObject{
                {QStringLiteral("schemeGuid"), candidate.first},
                {QStringLiteral("label"), candidate.second},
                {QStringLiteral("settings"), settings},
            };
        }
    }
    fail(QStringLiteral("Unable to resolve a complete heterogeneous scheduling baseline."));
}

class HeterogeneousPowerPolicyHandler final : public BaseHandler {
public:
    HeterogeneousPowerPolicyHandler()
        : BaseHandler(QStringLiteral("HeterogeneousPowerPolicy"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        try {
            const QJsonObject baseline = heterogeneousBaseline();
            return Requirement::available(
                QStringLiteral("Resolved baseline from %1.")
                    .arg(baseline.value(QStringLiteral("label")).toString())
            );
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const PowerScheme active = PowerConfig::activeScheme();
        const QJsonObject baseline = heterogeneousBaseline();
        QJsonArray settings;

        for (const QJsonValue &value : baseline.value(QStringLiteral("settings")).toArray()) {
            QJsonObject setting = value.toObject();
            const QString subgroupGuid = setting.value(QStringLiteral("subgroupGuid")).toString();
            const QString settingGuid = setting.value(QStringLiteral("settingGuid")).toString();
            const QJsonObject current = PowerConfig::settingValueSnapshot(
                active.guid,
                subgroupGuid,
                settingGuid
            );
            setting.insert(QStringLiteral("beforeAc"), current.value(QStringLiteral("ac")));
            setting.insert(QStringLiteral("beforeDc"), current.value(QStringLiteral("dc")));
            settings.append(setting);
        }

        return QJsonObject{
            {QStringLiteral("activeSchemeGuid"), active.guid},
            {QStringLiteral("activeSchemeName"), active.name},
            {
                QStringLiteral("baselineSchemeGuid"),
                baseline.value(QStringLiteral("schemeGuid")),
            },
            {
                QStringLiteral("baselineLabel"),
                baseline.value(QStringLiteral("label")),
            },
            {QStringLiteral("settings"), settings},
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString activeGuid = before.value(QStringLiteral("activeSchemeGuid")).toString();
        if (PowerConfig::activeScheme().guid != activeGuid) {
            fail(QStringLiteral("The active power scheme changed after the snapshot was taken."));
        }

        for (
            const QJsonValue &value :
            before.value(QStringLiteral("settings")).toArray()
        ) {
            const QJsonObject setting = value.toObject();
            PowerConfig::setAcValueIndex(
                activeGuid,
                setting.value(QStringLiteral("subgroupGuid")).toString(),
                setting.value(QStringLiteral("settingGuid")).toString(),
                setting.value(QStringLiteral("targetAc")).toInt()
            );
            PowerConfig::setDcValueIndex(
                activeGuid,
                setting.value(QStringLiteral("subgroupGuid")).toString(),
                setting.value(QStringLiteral("settingGuid")).toString(),
                setting.value(QStringLiteral("targetDc")).toInt()
            );
        }
        PowerConfig::setActive(activeGuid);
        return QJsonObject{
            {QStringLiteral("activeSchemeGuid"), activeGuid},
            {QStringLiteral("appliedAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        if (
            PowerConfig::activeScheme().guid
            != before.value(QStringLiteral("activeSchemeGuid")).toString()
        ) {
            return false;
        }
        for (
            const QJsonValue &value :
            before.value(QStringLiteral("settings")).toArray()
        ) {
            const QJsonObject setting = value.toObject();
            const QJsonObject current = PowerConfig::settingValueSnapshot(
                before.value(QStringLiteral("activeSchemeGuid")).toString(),
                setting.value(QStringLiteral("subgroupGuid")).toString(),
                setting.value(QStringLiteral("settingGuid")).toString()
            );
            if (
                current.value(QStringLiteral("ac")).toObject()
                    .value(QStringLiteral("value")).toInt()
                    != setting.value(QStringLiteral("targetAc")).toInt()
                || current.value(QStringLiteral("dc")).toObject()
                    .value(QStringLiteral("value")).toInt()
                    != setting.value(QStringLiteral("targetDc")).toInt()
            ) {
                return false;
            }
        }
        return true;
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString activeGuid = before.value(QStringLiteral("activeSchemeGuid")).toString();
        if (PowerConfig::activeScheme().guid != activeGuid) {
            fail(QStringLiteral("The active power scheme changed. Restore was blocked."));
        }

        const QString root = QStringLiteral(
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\%1\\%2\\%3"
        );
        for (
            const QJsonValue &value :
            before.value(QStringLiteral("settings")).toArray()
        ) {
            const QJsonObject setting = value.toObject();
            const QString path = root.arg(
                activeGuid,
                setting.value(QStringLiteral("subgroupGuid")).toString(),
                setting.value(QStringLiteral("settingGuid")).toString()
            );
            restoreRegistryEntry(
                RegistryValue::fromJson(setting.value(QStringLiteral("beforeAc")).toObject()),
                path,
                QStringLiteral("ACSettingIndex")
            );
            restoreRegistryEntry(
                RegistryValue::fromJson(setting.value(QStringLiteral("beforeDc")).toObject()),
                path,
                QStringLiteral("DCSettingIndex")
            );
        }
        PowerConfig::setActive(activeGuid);
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString root = QStringLiteral(
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes\\%1\\%2\\%3"
        );
        for (
            const QJsonValue &value :
            before.value(QStringLiteral("settings")).toArray()
        ) {
            const QJsonObject setting = value.toObject();
            const QString path = root.arg(
                before.value(QStringLiteral("activeSchemeGuid")).toString(),
                setting.value(QStringLiteral("subgroupGuid")).toString(),
                setting.value(QStringLiteral("settingGuid")).toString()
            );
            if (
                !RegistryStore::equivalent(
                    RegistryStore::read(path, QStringLiteral("ACSettingIndex")),
                    RegistryValue::fromJson(
                        setting.value(QStringLiteral("beforeAc")).toObject()
                    )
                )
                || !RegistryStore::equivalent(
                    RegistryStore::read(path, QStringLiteral("DCSettingIndex")),
                    RegistryValue::fromJson(
                        setting.value(QStringLiteral("beforeDc")).toObject()
                    )
                )
            ) {
                return false;
            }
        }
        return true;
    }
};

class BcdTimersHandler final : public BaseHandler {
public:
    BcdTimersHandler()
        : BaseHandler(QStringLiteral("BcdTimers"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return ProcessRunner::findExecutable(QStringLiteral("bcdedit.exe")).isEmpty()
            ? Requirement::unavailable(QStringLiteral("bcdedit.exe is unavailable."))
            : Requirement::available(QStringLiteral("bcdedit.exe is available."));
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return QJsonObject{
            {QStringLiteral("useplatformtick"), bcdValue(QStringLiteral("useplatformtick"))},
            {QStringLiteral("disabledynamictick"), bcdValue(QStringLiteral("disabledynamictick"))},
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(before);
        Q_UNUSED(context);
        setBcdValue(QStringLiteral("useplatformtick"), QStringLiteral("no"));
        setBcdValue(QStringLiteral("disabledynamictick"), QStringLiteral("yes"));
        return snapshot(RuleDefinition{}, RuleOptions{}, OperationContext{});
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(snapshot);
        Q_UNUSED(context);
        const QJsonObject current = readTimers();
        return current.value(QStringLiteral("useplatformtick"))
                   .toObject().value(QStringLiteral("value")).toString()
                   .compare(QStringLiteral("No"), Qt::CaseInsensitive) == 0
            && current.value(QStringLiteral("disabledynamictick"))
                   .toObject().value(QStringLiteral("value")).toString()
                   .compare(QStringLiteral("Yes"), Qt::CaseInsensitive) == 0;
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        for (const QString &name : {
                 QStringLiteral("useplatformtick"),
                 QStringLiteral("disabledynamictick"),
             }) {
            const QJsonObject entry = before.value(name).toObject();
            if (entry.value(QStringLiteral("exists")).toBool()) {
                setBcdValue(name, entry.value(QStringLiteral("value")).toString());
            } else {
                deleteBcdValue(name);
            }
        }
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject current = readTimers();
        for (const QString &name : {
                 QStringLiteral("useplatformtick"),
                 QStringLiteral("disabledynamictick"),
             }) {
            if (
                current.value(name).toObject().value(QStringLiteral("exists")).toBool()
                != before.value(name).toObject().value(QStringLiteral("exists")).toBool()
                || current.value(name).toObject().value(QStringLiteral("value")).toString()
                    != before.value(name).toObject().value(QStringLiteral("value")).toString()
            ) {
                return false;
            }
        }
        return true;
    }

private:
    static QJsonObject bcdValue(const QString &name)
    {
        const CommandResult result = ProcessRunner::run(
            QStringLiteral("bcdedit.exe"),
            {QStringLiteral("/enum"), QStringLiteral("{current}"), QStringLiteral("/v")}
        );
        if (!result.success()) {
            fail(result.combinedOutput());
        }
        const QRegularExpression expression(
            QStringLiteral("(?im)^\\s*%1\\s+(\\S+)")
                .arg(QRegularExpression::escape(name))
        );
        const QRegularExpressionMatch match = expression.match(result.standardOutput);
        return QJsonObject{
            {QStringLiteral("name"), name},
            {QStringLiteral("exists"), match.hasMatch()},
            {
                QStringLiteral("value"),
                match.hasMatch() ? QJsonValue(match.captured(1)) : QJsonValue(QJsonValue::Null),
            },
        };
    }

    static QJsonObject readTimers()
    {
        return QJsonObject{
            {QStringLiteral("useplatformtick"), bcdValue(QStringLiteral("useplatformtick"))},
            {QStringLiteral("disabledynamictick"), bcdValue(QStringLiteral("disabledynamictick"))},
        };
    }

    static void setBcdValue(const QString &name, const QString &value)
    {
        const CommandResult result = ProcessRunner::run(
            QStringLiteral("bcdedit.exe"),
            {QStringLiteral("/set"), name, value}
        );
        if (!result.success()) {
            fail(result.combinedOutput());
        }
    }

    static void deleteBcdValue(const QString &name)
    {
        const CommandResult result = ProcessRunner::run(
            QStringLiteral("bcdedit.exe"),
            {QStringLiteral("/deletevalue"), name}
        );
        if (
            !result.success()
            && !result.combinedOutput().contains(QStringLiteral("not found"), Qt::CaseInsensitive)
            && !result.combinedOutput().contains(QStringLiteral("找不到"))
        ) {
            fail(result.combinedOutput());
        }
    }
};

struct TcpGlobalState {
    QString autoTuning;
    QString timestamps;
    QString raw;

    QJsonObject toJson() const
    {
        return QJsonObject{
            {QStringLiteral("autoTuning"), autoTuning},
            {QStringLiteral("timestamps"), timestamps},
        };
    }
};

TcpGlobalState readTcpGlobal()
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("netsh.exe"),
        {
            QStringLiteral("int"),
            QStringLiteral("tcp"),
            QStringLiteral("show"),
            QStringLiteral("global"),
        }
    );
    if (!result.success()) {
        fail(result.combinedOutput());
    }

    TcpGlobalState state;
    state.raw = result.standardOutput;
    const QRegularExpression autoTuning(
        QStringLiteral(
            "(?im)^\\s*(?:Receive Window Auto-Tuning Level|"
            "接收窗口自动调优级别)\\s*:\\s*(\\S+)"
        )
    );
    const QRegularExpression timestamps(
        QStringLiteral(
            "(?im)^\\s*(?:RFC 1323 Timestamps|RFC 1323 时间戳)\\s*:\\s*(\\S+)"
        )
    );
    const QRegularExpressionMatch autoTuningMatch = autoTuning.match(state.raw);
    const QRegularExpressionMatch timestampsMatch = timestamps.match(state.raw);
    if (autoTuningMatch.hasMatch()) {
        state.autoTuning = autoTuningMatch.captured(1).toLower();
    }
    if (timestampsMatch.hasMatch()) {
        state.timestamps = timestampsMatch.captured(1).toLower();
    }
    if (state.autoTuning.isEmpty() || state.timestamps.isEmpty()) {
        fail(QStringLiteral("Unable to read TCP auto-tuning and timestamp state."));
    }
    return state;
}

void setTcpProperty(const QString &property, const QString &value)
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("netsh.exe"),
        {
            QStringLiteral("int"),
            QStringLiteral("tcp"),
            QStringLiteral("set"),
            QStringLiteral("global"),
            QStringLiteral("%1=%2").arg(property, value),
        }
    );
    if (!result.success()) {
        fail(result.combinedOutput());
    }
}

class TcpGlobalHandler final : public BaseHandler {
public:
    TcpGlobalHandler(QString handlerId, bool autoTuning)
        : BaseHandler(std::move(handlerId))
        , m_autoTuning(autoTuning)
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        if (ProcessRunner::findExecutable(QStringLiteral("netsh.exe")).isEmpty()) {
            return Requirement::unavailable(QStringLiteral("netsh.exe is unavailable."));
        }
        try {
            readTcpGlobal();
            return Requirement::available(QStringLiteral("TCP global settings are readable."));
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        return readTcpGlobal().toJson();
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        if (m_autoTuning) {
            setTcpProperty(QStringLiteral("autotuninglevel"), QStringLiteral("experimental"));
        } else {
            setTcpProperty(QStringLiteral("timestamps"), QStringLiteral("enabled"));
        }
        QJsonObject after = readTcpGlobal().toJson();
        after.insert(
            QStringLiteral("expectedAutoTuning"),
            m_autoTuning
                ? QStringLiteral("experimental")
                : before.value(QStringLiteral("autoTuning"))
        );
        after.insert(
            QStringLiteral("expectedTimestamps"),
            m_autoTuning
                ? before.value(QStringLiteral("timestamps"))
                : QStringLiteral("enabled")
        );
        return after;
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const TcpGlobalState current = readTcpGlobal();
        return m_autoTuning
            ? current.autoTuning == after.value(QStringLiteral("expectedAutoTuning")).toString()
            : current.timestamps == after.value(QStringLiteral("expectedTimestamps")).toString();
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        setTcpProperty(
            QStringLiteral("autotuninglevel"),
            before.value(QStringLiteral("autoTuning")).toString()
        );
        setTcpProperty(
            QStringLiteral("timestamps"),
            before.value(QStringLiteral("timestamps")).toString()
        );
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const TcpGlobalState current = readTcpGlobal();
        return current.autoTuning == before.value(QStringLiteral("autoTuning")).toString()
            && current.timestamps == before.value(QStringLiteral("timestamps")).toString();
    }

private:
    bool m_autoTuning = false;
};

QString adapterRegistryPath(const RuleOptions &options)
{
    QString adapterName = options.stringValue(QStringLiteral("InterfaceAlias"));
    if (adapterName.isEmpty()) {
        adapterName = options.stringValue(QStringLiteral("AdapterName"));
    }
    if (adapterName.isEmpty()) {
        fail(QStringLiteral("An adapter name or interface alias is required."));
    }

    QString guid = options.stringValue(QStringLiteral("InterfaceGuid"));
    if (guid.isEmpty()) {
        guid = NetworkAdapters::interfaceGuid(adapterName);
    }
    if (guid.isEmpty()) {
        fail(QStringLiteral("The selected network adapter was not found."));
    }

    const QString path = NetworkAdapters::classRegistryPath(guid);
    if (path.isEmpty()) {
        fail(QStringLiteral("Unable to resolve the adapter registry key."));
    }
    return path;
}

class NicPowerHandler final : public BaseHandler {
public:
    NicPowerHandler()
        : BaseHandler(QStringLiteral("NicPower"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        try {
            adapterRegistryPath(options);
            return Requirement::available(QStringLiteral("The selected network adapter is available."));
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString path = adapterRegistryPath(options);
        return QJsonObject{
            {
                QStringLiteral("adapterName"),
                options.stringValue(
                    QStringLiteral("InterfaceAlias"),
                    options.stringValue(QStringLiteral("AdapterName"))
                ),
            },
            {QStringLiteral("registryPath"), path},
            {
                QStringLiteral("registry"),
                RegistryStore::read(path, QStringLiteral("PnPCapabilities")).toJson(),
            },
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        const RegistryValue current = RegistryValue::fromJson(
            before.value(QStringLiteral("registry")).toObject()
        );
        const quint32 value = (current.exists ? current.value.toUInt() : 0U) | 0x100U;
        RegistryStore::write(path, QStringLiteral("PnPCapabilities"), QStringLiteral("DWord"), value);
        return QJsonObject{
            {
                QStringLiteral("registry"),
                RegistryStore::read(path, QStringLiteral("PnPCapabilities")).toJson(),
            },
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        return RegistryStore::equivalent(
            RegistryStore::read(
                before.value(QStringLiteral("registryPath")).toString(),
                QStringLiteral("PnPCapabilities")
            ),
            RegistryValue::fromJson(
                snapshot.value(QStringLiteral("after")).toObject()
                    .value(QStringLiteral("registry")).toObject()
            )
        );
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        restoreRegistryEntry(
            RegistryValue::fromJson(before.value(QStringLiteral("registry")).toObject()),
            before.value(QStringLiteral("registryPath")).toString(),
            QStringLiteral("PnPCapabilities")
        );
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        return RegistryStore::equivalent(
            RegistryStore::read(
                before.value(QStringLiteral("registryPath")).toString(),
                QStringLiteral("PnPCapabilities")
            ),
            RegistryValue::fromJson(before.value(QStringLiteral("registry")).toObject())
        );
    }
};

class NetworkInterruptModerationHandler final : public BaseHandler {
public:
    NetworkInterruptModerationHandler()
        : BaseHandler(QStringLiteral("NetworkInterruptModeration"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        try {
            const QString path = adapterRegistryPath(options);
            if (
                !RegistryStore::read(path, QStringLiteral("*InterruptModeration")).exists
                && !RegistryStore::read(path, QStringLiteral("InterruptModeration")).exists
            ) {
                return Requirement::unavailable(
                    QStringLiteral("The selected adapter does not expose interrupt moderation.")
                );
            }
            return Requirement::available(
                QStringLiteral("Interrupt moderation is available on the selected adapter.")
            );
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString path = adapterRegistryPath(options);
        const bool starred = RegistryStore::read(
            path,
            QStringLiteral("*InterruptModeration")
        ).exists;
        const QString valueName = starred
            ? QStringLiteral("*InterruptModeration")
            : QStringLiteral("InterruptModeration");
        return QJsonObject{
            {QStringLiteral("registryPath"), path},
            {QStringLiteral("valueName"), valueName},
            {
                QStringLiteral("registry"),
                RegistryStore::read(path, valueName).toJson(),
            },
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        const QString valueName = before.value(QStringLiteral("valueName")).toString();
        RegistryStore::write(path, valueName, QStringLiteral("DWord"), 0U);
        return QJsonObject{
            {QStringLiteral("registry"), RegistryStore::read(path, valueName).toJson()},
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        return RegistryStore::equivalent(
            RegistryStore::read(
                before.value(QStringLiteral("registryPath")).toString(),
                before.value(QStringLiteral("valueName")).toString()
            ),
            RegistryValue::fromJson(
                snapshot.value(QStringLiteral("after")).toObject()
                    .value(QStringLiteral("registry")).toObject()
            )
        );
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        restoreRegistryEntry(
            RegistryValue::fromJson(before.value(QStringLiteral("registry")).toObject()),
            before.value(QStringLiteral("registryPath")).toString(),
            before.value(QStringLiteral("valueName")).toString()
        );
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        return RegistryStore::equivalent(
            RegistryStore::read(
                before.value(QStringLiteral("registryPath")).toString(),
                before.value(QStringLiteral("valueName")).toString()
            ),
            RegistryValue::fromJson(before.value(QStringLiteral("registry")).toObject())
        );
    }
};

class AmdDynamicPstateHandler final : public RegistrySetHandler {
public:
    AmdDynamicPstateHandler()
        : RegistrySetHandler(QStringLiteral("AmdDynamicPstate"))
    {
    }

protected:
    QJsonArray registryChanges(
        const RuleDefinition &rule,
        const RuleOptions &options
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        const QString root = QStringLiteral(
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\"
            "{4d36e968-e325-11ce-bfc1-08002be10318}"
        );
        for (const QString &subKey : RegistryStore::subKeys(root)) {
            if (!QRegularExpression(QStringLiteral("^\\d{4}$")).match(subKey).hasMatch()) {
                continue;
            }
            const QString path = root + QLatin1Char('\\') + subKey;
            const QString provider = RegistryStore::read(
                path,
                QStringLiteral("ProviderName")
            ).value.toString();
            const QString description = RegistryStore::read(
                path,
                QStringLiteral("DriverDesc")
            ).value.toString();
            if (
                (provider + QLatin1Char(' ') + description).contains(
                    QRegularExpression(
                        QStringLiteral("AMD|Advanced Micro Devices|Radeon"),
                        QRegularExpression::CaseInsensitiveOption
                    )
                )
            ) {
                return QJsonArray{
                    QJsonObject{
                        {QStringLiteral("path"), path},
                        {QStringLiteral("name"), QStringLiteral("DisableDynamicPstate")},
                        {QStringLiteral("kind"), QStringLiteral("DWord")},
                        {QStringLiteral("value"), 1},
                    },
                };
            }
        }
        return {};
    }
};

struct DnsProfileState {
    QString interfaceAlias;
    QStringList servers;
    bool dhcp = false;

    QJsonObject toJson() const
    {
        return QJsonObject{
            {QStringLiteral("interfaceAlias"), interfaceAlias},
            {QStringLiteral("servers"), QJsonArray::fromStringList(servers)},
            {QStringLiteral("dhcp"), dhcp},
        };
    }
};

DnsProfileState readDnsProfile(const QString &interfaceAlias)
{
    const CommandResult result = ProcessRunner::run(
        QStringLiteral("netsh.exe"),
        {
            QStringLiteral("interface"),
            QStringLiteral("ipv4"),
            QStringLiteral("show"),
            QStringLiteral("dnsservers"),
            QStringLiteral("name=%1").arg(interfaceAlias),
        }
    );
    if (!result.success()) {
        fail(result.combinedOutput());
    }

    DnsProfileState state;
    state.interfaceAlias = interfaceAlias;
    state.dhcp = result.standardOutput.contains(
        QStringLiteral("DHCP"),
        Qt::CaseInsensitive
    );
    const QRegularExpression address(
        QStringLiteral("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    );
    auto iterator = address.globalMatch(result.standardOutput);
    while (iterator.hasNext()) {
        const QString server = iterator.next().captured(0);
        if (!state.servers.contains(server)) {
            state.servers.append(server);
        }
    }
    return state;
}

void applyDnsProfile(
    const QString &interfaceAlias,
    bool dhcp,
    const QStringList &servers
)
{
    if (dhcp) {
        const CommandResult result = ProcessRunner::run(
            QStringLiteral("netsh.exe"),
            {
                QStringLiteral("interface"),
                QStringLiteral("ipv4"),
                QStringLiteral("set"),
                QStringLiteral("dnsservers"),
                QStringLiteral("name=%1").arg(interfaceAlias),
                QStringLiteral("source=dhcp"),
            }
        );
        if (!result.success()) {
            fail(result.combinedOutput());
        }
        return;
    }

    if (servers.isEmpty()) {
        fail(QStringLiteral("At least one DNS server is required."));
    }

    const CommandResult primary = ProcessRunner::run(
        QStringLiteral("netsh.exe"),
        {
            QStringLiteral("interface"),
            QStringLiteral("ipv4"),
            QStringLiteral("set"),
            QStringLiteral("dnsservers"),
            QStringLiteral("name=%1").arg(interfaceAlias),
            QStringLiteral("source=static"),
            QStringLiteral("address=%1").arg(servers.first()),
            QStringLiteral("register=primary"),
            QStringLiteral("validate=no"),
        }
    );
    if (!primary.success()) {
        fail(primary.combinedOutput());
    }

    for (int index = 1; index < servers.size(); ++index) {
        const CommandResult secondary = ProcessRunner::run(
            QStringLiteral("netsh.exe"),
            {
                QStringLiteral("interface"),
                QStringLiteral("ipv4"),
                QStringLiteral("add"),
                QStringLiteral("dnsservers"),
                QStringLiteral("name=%1").arg(interfaceAlias),
                QStringLiteral("address=%1").arg(servers.at(index)),
                QStringLiteral("index=%1").arg(index + 1),
                QStringLiteral("validate=no"),
            }
        );
        if (!secondary.success()) {
            fail(secondary.combinedOutput());
        }
    }
}

class DnsProfileHandler final : public BaseHandler {
public:
    DnsProfileHandler()
        : BaseHandler(QStringLiteral("DnsProfile"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString alias = options.stringValue(QStringLiteral("InterfaceAlias"));
        if (alias.isEmpty()) {
            return Requirement::unavailable(QStringLiteral("InterfaceAlias is required."));
        }
        if (
            !options.boolValue(QStringLiteral("Dhcp"))
            && options.stringList(QStringLiteral("DnsServers")).isEmpty()
        ) {
            return Requirement::unavailable(
                QStringLiteral("DnsServers is required when DHCP DNS is disabled.")
            );
        }
        try {
            readDnsProfile(alias);
            return Requirement::available(QStringLiteral("The selected network interface is available."));
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        return readDnsProfile(
            options.stringValue(QStringLiteral("InterfaceAlias"))
        ).toJson();
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const bool dhcp = options.boolValue(QStringLiteral("Dhcp"));
        const QStringList servers = options.stringList(QStringLiteral("DnsServers"));
        applyDnsProfile(
            before.value(QStringLiteral("interfaceAlias")).toString(),
            dhcp,
            servers
        );
        QJsonObject after = readDnsProfile(
            before.value(QStringLiteral("interfaceAlias")).toString()
        ).toJson();
        after.insert(QStringLiteral("expectedDhcp"), dhcp);
        after.insert(
            QStringLiteral("expectedServers"),
            QJsonArray::fromStringList(servers)
        );
        return after;
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const DnsProfileState current = readDnsProfile(
            before.value(QStringLiteral("interfaceAlias")).toString()
        );
        if (after.value(QStringLiteral("expectedDhcp")).toBool()) {
            return current.dhcp;
        }
        QStringList expected;
        for (const QJsonValue &value : after.value(QStringLiteral("expectedServers")).toArray()) {
            expected.append(value.toString());
        }
        return current.servers == expected;
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        QStringList servers;
        for (const QJsonValue &value : before.value(QStringLiteral("servers")).toArray()) {
            servers.append(value.toString());
        }
        applyDnsProfile(
            before.value(QStringLiteral("interfaceAlias")).toString(),
            before.value(QStringLiteral("dhcp")).toBool(),
            servers
        );
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const DnsProfileState current = readDnsProfile(
            before.value(QStringLiteral("interfaceAlias")).toString()
        );
        if (before.value(QStringLiteral("dhcp")).toBool()) {
            return current.dhcp;
        }
        QStringList servers;
        for (const QJsonValue &value : before.value(QStringLiteral("servers")).toArray()) {
            servers.append(value.toString());
        }
        return current.servers == servers;
    }
};

const QSet<QString> &allowedServices()
{
    static const QSet<QString> services{
        QStringLiteral("SysMain"),
        QStringLiteral("WSearch"),
        QStringLiteral("Spooler"),
        QStringLiteral("XblAuthManager"),
        QStringLiteral("XblGameSave"),
        QStringLiteral("XboxNetApiSvc"),
        QStringLiteral("DiagTrack"),
    };
    return services;
}

#ifdef FELIX_PLATFORM_WINDOWS

QString serviceStartTypeName(DWORD startType)
{
    switch (startType) {
    case SERVICE_AUTO_START:
        return QStringLiteral("Automatic");
    case SERVICE_DEMAND_START:
        return QStringLiteral("Manual");
    case SERVICE_DISABLED:
        return QStringLiteral("Disabled");
    default:
        return QStringLiteral("Unknown");
    }
}

DWORD serviceStartTypeValue(const QString &name)
{
    if (name.compare(QStringLiteral("Automatic"), Qt::CaseInsensitive) == 0) {
        return SERVICE_AUTO_START;
    }
    if (name.compare(QStringLiteral("Manual"), Qt::CaseInsensitive) == 0) {
        return SERVICE_DEMAND_START;
    }
    if (name.compare(QStringLiteral("Disabled"), Qt::CaseInsensitive) == 0) {
        return SERVICE_DISABLED;
    }
    fail(QStringLiteral("Unsupported service startup type '%1'.").arg(name));
}

QString serviceStatusName(DWORD status)
{
    switch (status) {
    case SERVICE_RUNNING:
        return QStringLiteral("Running");
    case SERVICE_STOPPED:
        return QStringLiteral("Stopped");
    case SERVICE_START_PENDING:
        return QStringLiteral("StartPending");
    case SERVICE_STOP_PENDING:
        return QStringLiteral("StopPending");
    case SERVICE_PAUSED:
        return QStringLiteral("Paused");
    default:
        return QStringLiteral("Unknown");
    }
}

QJsonObject serviceSnapshot(const QString &serviceName)
{
    const std::wstring name = serviceName.toStdWString();
    SC_HANDLE manager = OpenSCManagerW(
        nullptr,
        nullptr,
        SC_MANAGER_CONNECT
    );
    if (manager == nullptr) {
        fail(QStringLiteral("Unable to open the service control manager."));
    }
    SC_HANDLE service = OpenServiceW(
        manager,
        name.c_str(),
        SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS
    );
    if (service == nullptr) {
        CloseServiceHandle(manager);
        fail(QStringLiteral("Service '%1' was not found.").arg(serviceName));
    }

    DWORD required = 0;
    QueryServiceConfigW(service, nullptr, 0, &required);
    QByteArray configBuffer(static_cast<int>(required), Qt::Uninitialized);
    auto *config = reinterpret_cast<LPQUERY_SERVICE_CONFIGW>(configBuffer.data());
    if (!QueryServiceConfigW(service, config, required, &required)) {
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        fail(QStringLiteral("Unable to query service configuration."));
    }

    SERVICE_STATUS_PROCESS status{};
    DWORD statusBytes = 0;
    if (
        !QueryServiceStatusEx(
            service,
            SC_STATUS_PROCESS_INFO,
            reinterpret_cast<LPBYTE>(&status),
            sizeof(status),
            &statusBytes
        )
    ) {
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        fail(QStringLiteral("Unable to query service status."));
    }

    const QJsonObject result{
        {QStringLiteral("name"), serviceName},
        {
            QStringLiteral("displayName"),
            config->lpDisplayName != nullptr
                ? QString::fromWCharArray(config->lpDisplayName)
                : serviceName,
        },
        {QStringLiteral("startType"), serviceStartTypeName(config->dwStartType)},
        {QStringLiteral("status"), serviceStatusName(status.dwCurrentState)},
    };
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return result;
}

void changeServiceState(
    const QString &serviceName,
    const QString &startType,
    const QString &desiredStatus
)
{
    const std::wstring name = serviceName.toStdWString();
    SC_HANDLE manager = OpenSCManagerW(
        nullptr,
        nullptr,
        SC_MANAGER_CONNECT
    );
    if (manager == nullptr) {
        fail(QStringLiteral("Unable to open the service control manager."));
    }
    SC_HANDLE service = OpenServiceW(
        manager,
        name.c_str(),
        SERVICE_CHANGE_CONFIG | SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS
    );
    if (service == nullptr) {
        CloseServiceHandle(manager);
        fail(QStringLiteral("Service '%1' was not found.").arg(serviceName));
    }

    if (
        !ChangeServiceConfigW(
            service,
            SERVICE_NO_CHANGE,
            serviceStartTypeValue(startType),
            SERVICE_NO_CHANGE,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            nullptr
        )
    ) {
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        fail(QStringLiteral("Unable to change service startup type."));
    }

    SERVICE_STATUS_PROCESS status{};
    DWORD statusBytes = 0;
    QueryServiceStatusEx(
        service,
        SC_STATUS_PROCESS_INFO,
        reinterpret_cast<LPBYTE>(&status),
        sizeof(status),
        &statusBytes
    );
    if (
        desiredStatus == QStringLiteral("Running")
        && status.dwCurrentState != SERVICE_RUNNING
    ) {
        if (!StartServiceW(service, 0, nullptr)) {
            const DWORD error = GetLastError();
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            if (error != ERROR_SERVICE_ALREADY_RUNNING) {
                fail(QStringLiteral("Unable to start service '%1'.").arg(serviceName));
            }
            return;
        }
    } else if (
        desiredStatus == QStringLiteral("Stopped")
        && status.dwCurrentState != SERVICE_STOPPED
    ) {
        SERVICE_STATUS stopStatus{};
        ControlService(service, SERVICE_CONTROL_STOP, &stopStatus);
    }

    CloseServiceHandle(service);
    CloseServiceHandle(manager);
}

#endif

class ServiceStateHandler final : public BaseHandler {
public:
    ServiceStateHandler()
        : BaseHandler(QStringLiteral("ServiceState"))
    {
    }

    explicit ServiceStateHandler(QString handlerId)
        : BaseHandler(std::move(handlerId))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(context);
        const QString serviceName = resolvedServiceName(rule, options);
        if (serviceName.isEmpty()) {
            return Requirement::unavailable(QStringLiteral("ServiceName is required."));
        }
        if (!allowedServices().contains(serviceName)) {
            return Requirement::unavailable(
                QStringLiteral("Service '%1' is not in the allowlist.").arg(serviceName)
            );
        }
#ifdef FELIX_PLATFORM_WINDOWS
        try {
            serviceSnapshot(serviceName);
            return Requirement::available(
                QStringLiteral("Service '%1' is available.").arg(serviceName)
            );
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
#else
        return Requirement::unavailable(QStringLiteral("Service operations require Windows."));
#endif
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(context);
#ifdef FELIX_PLATFORM_WINDOWS
        return serviceSnapshot(resolvedServiceName(rule, options));
#else
        fail(QStringLiteral("Service operations require Windows."));
#endif
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(context);
        const QString startType = options.stringValue(
            QStringLiteral("StartupType"),
            ruleValue(rule, QStringLiteral("targetStartupType"), QStringLiteral("Manual"))
        );
        const bool stopNow = options.contains(QStringLiteral("StopNow"))
            ? options.boolValue(QStringLiteral("StopNow"))
            : ruleBoolValue(
                  rule,
                  QStringLiteral("stopNow"),
                  startType == QStringLiteral("Disabled")
              );
#ifdef FELIX_PLATFORM_WINDOWS
        changeServiceState(
            before.value(QStringLiteral("name")).toString(),
            startType,
            stopNow ? QStringLiteral("Stopped") : before.value(QStringLiteral("status")).toString()
        );
        QJsonObject after = serviceSnapshot(
            before.value(QStringLiteral("name")).toString()
        );
        after.insert(QStringLiteral("requestedStartType"), startType);
        after.insert(QStringLiteral("requestedStop"), stopNow);
        return after;
#else
        Q_UNUSED(before);
        Q_UNUSED(stopNow);
        fail(QStringLiteral("Service operations require Windows."));
#endif
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
#ifdef FELIX_PLATFORM_WINDOWS
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const QJsonObject current = serviceSnapshot(
            before.value(QStringLiteral("name")).toString()
        );
        return current.value(QStringLiteral("startType")).toString()
                == after.value(QStringLiteral("startType")).toString()
            && (
                !after.value(QStringLiteral("requestedStop")).toBool()
                || current.value(QStringLiteral("status")).toString()
                    != QStringLiteral("Running")
            );
#else
        return false;
#endif
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
#ifdef FELIX_PLATFORM_WINDOWS
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        changeServiceState(
            before.value(QStringLiteral("name")).toString(),
            before.value(QStringLiteral("startType")).toString(),
            before.value(QStringLiteral("status")).toString()
        );
#else
        fail(QStringLiteral("Service operations require Windows."));
#endif
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
#ifdef FELIX_PLATFORM_WINDOWS
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject current = serviceSnapshot(
            before.value(QStringLiteral("name")).toString()
        );
        return current.value(QStringLiteral("startType")).toString()
                == before.value(QStringLiteral("startType")).toString()
            && current.value(QStringLiteral("status")).toString()
                == before.value(QStringLiteral("status")).toString();
#else
        return false;
#endif
    }

private:
    QString resolvedServiceName(
        const RuleDefinition &rule,
        const RuleOptions &options
    ) const
    {
        return options.stringValue(
            QStringLiteral("ServiceName"),
            ruleValue(rule, QStringLiteral("serviceName"))
        );
    }
};

const QStringList &allowedStartupRoots()
{
    static const QStringList roots{
        QStringLiteral("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
        QStringLiteral("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"),
        QStringLiteral("HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
        QStringLiteral("HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"),
    };
    return roots;
}

class StartupItemHandler final : public BaseHandler {
public:
    StartupItemHandler()
        : BaseHandler(QStringLiteral("StartupItem"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString path = windows::normalizeRegistryPath(
            options.stringValue(QStringLiteral("RegistryPath"))
        );
        const QString valueName = options.stringValue(QStringLiteral("ValueName"));
        if (path.isEmpty() || valueName.isEmpty()) {
            return Requirement::unavailable(
                QStringLiteral("RegistryPath and ValueName are required.")
            );
        }
        const bool allowed = std::any_of(
            allowedStartupRoots().cbegin(),
            allowedStartupRoots().cend(),
            [&path](const QString &root) {
                return path.compare(root, Qt::CaseInsensitive) == 0;
            }
        );
        if (!allowed) {
            return Requirement::unavailable(
                QStringLiteral("The selected startup registry key is not supported.")
            );
        }
        if (
            !options.boolValue(QStringLiteral("Enable"))
            && !RegistryStore::read(path, valueName).exists
        ) {
            return Requirement::unavailable(
                QStringLiteral("The selected startup item does not exist.")
            );
        }
        return Requirement::available(QStringLiteral("The startup item is available."));
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const bool enable = options.boolValue(QStringLiteral("Enable"));
        const QString path = windows::normalizeRegistryPath(
            options.stringValue(QStringLiteral("RegistryPath"))
        );
        const QString valueName = options.stringValue(QStringLiteral("ValueName"));
        RegistryValue value = RegistryStore::read(path, valueName);
        if (enable && !value.exists) {
            value.exists = true;
            value.kind = options.stringValue(QStringLiteral("ValueKind"));
            value.value = registryTargetVariant(
                QJsonValue::fromVariant(options.value(QStringLiteral("Value"))),
                value.kind
            );
        }
        return QJsonObject{
            {QStringLiteral("mode"), enable ? QStringLiteral("enable") : QStringLiteral("disable")},
            {QStringLiteral("registryPath"), path},
            {QStringLiteral("valueName"), valueName},
            {QStringLiteral("value"), value.toJson()},
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        const QString valueName = before.value(QStringLiteral("valueName")).toString();
        if (before.value(QStringLiteral("mode")).toString() == QStringLiteral("disable")) {
            RegistryStore::remove(path, valueName);
            return QJsonObject{
                {QStringLiteral("mode"), QStringLiteral("disable")},
                {QStringLiteral("registryPath"), path},
                {QStringLiteral("valueName"), valueName},
            };
        }

        RegistryValue value = RegistryValue::fromJson(
            before.value(QStringLiteral("value")).toObject()
        );
        RegistryStore::write(path, valueName, value.kind, value.value);
        return QJsonObject{
            {QStringLiteral("mode"), QStringLiteral("enable")},
            {QStringLiteral("registryPath"), path},
            {QStringLiteral("valueName"), valueName},
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        const RegistryValue current = RegistryStore::read(
            after.value(QStringLiteral("registryPath")).toString(),
            after.value(QStringLiteral("valueName")).toString()
        );
        return after.value(QStringLiteral("mode")).toString() == QStringLiteral("disable")
            ? !current.exists
            : current.exists;
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        const QString valueName = before.value(QStringLiteral("valueName")).toString();
        if (before.value(QStringLiteral("mode")).toString() == QStringLiteral("disable")) {
            restoreRegistryEntry(
                RegistryValue::fromJson(before.value(QStringLiteral("value")).toObject()),
                path,
                valueName
            );
        } else {
            RegistryStore::remove(path, valueName);
        }
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const RegistryValue current = RegistryStore::read(
            before.value(QStringLiteral("registryPath")).toString(),
            before.value(QStringLiteral("valueName")).toString()
        );
        return before.value(QStringLiteral("mode")).toString() == QStringLiteral("disable")
            ? RegistryStore::equivalent(
                  current,
                  RegistryValue::fromJson(before.value(QStringLiteral("value")).toObject())
              )
            : !current.exists;
    }
};

bool pathWithin(const QString &path, const QString &root)
{
    const QString normalizedPath = QDir::cleanPath(path);
    const QString normalizedRoot = QDir::cleanPath(root);
    return normalizedPath.compare(normalizedRoot, Qt::CaseInsensitive) == 0
        || normalizedPath.startsWith(
            normalizedRoot + QDir::separator(),
            Qt::CaseInsensitive
        );
}

bool canOpenExclusive(const QString &path)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const std::wstring nativePath = QDir::toNativeSeparators(path).toStdWString();
    const HANDLE file = CreateFileW(
        nativePath.c_str(),
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    CloseHandle(file);
    return true;
#else
    QFile file(path);
    return file.open(QIODevice::ReadWrite | QIODevice::ExistingOnly);
#endif
}

bool moveFile(const QString &source, const QString &destination)
{
    QDir().mkpath(QFileInfo(destination).absolutePath());
    if (QFile::rename(source, destination)) {
        return true;
    }
    if (!QFile::copy(source, destination)) {
        return false;
    }
    return QFile::remove(source);
}

class TempQuarantineHandler final : public BaseHandler {
public:
    TempQuarantineHandler()
        : BaseHandler(QStringLiteral("TempQuarantine"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        const QFileInfo tempRoot(QDir::tempPath());
        if (!tempRoot.isDir()) {
            return Requirement::unavailable(QStringLiteral("The user temp directory is unavailable."));
        }
        if (context.stateRoot.isEmpty()) {
            return Requirement::unavailable(QStringLiteral("The state root is unavailable."));
        }
        return Requirement::available(QStringLiteral("The user temp directory is readable."));
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        const int olderThanDays = options.intValue(QStringLiteral("OlderThanDays"), 7);
        const qint64 maxBytes = static_cast<qint64>(
            options.value(QStringLiteral("MaxBytes")).toLongLong()
        );
        const int maxFiles = options.intValue(QStringLiteral("MaxFiles"), 5000);
        const qint64 byteLimit = maxBytes > 0 ? maxBytes : 2147483648LL;

        const QString tempRoot = QDir::cleanPath(QDir::tempPath());
        const QString quarantineRoot = QDir(
            context.stateRoot
        ).filePath(QStringLiteral("quarantine/%1").arg(context.operationId));
        const QDateTime cutoff = QDateTime::currentDateTime().addDays(-olderThanDays);
        QJsonArray files;
        qint64 totalBytes = 0;
        int skipped = 0;

        QDirIterator iterator(
            tempRoot,
            QDir::Files | QDir::Hidden | QDir::NoSymLinks,
            QDirIterator::Subdirectories
        );
        while (iterator.hasNext()) {
            iterator.next();
            if (files.size() >= maxFiles || totalBytes >= byteLimit) {
                break;
            }
            const QFileInfo info = iterator.fileInfo();
            const QString source = QDir::cleanPath(info.absoluteFilePath());
            if (
                pathWithin(source, context.stateRoot)
                || info.lastModified() > cutoff
            ) {
                continue;
            }
            if (!canOpenExclusive(source)) {
                ++skipped;
                continue;
            }
            if (totalBytes + info.size() > byteLimit) {
                continue;
            }

            const QString relativePath = QDir(tempRoot).relativeFilePath(source);
            const QString destination = QDir(quarantineRoot)
                .filePath(QStringLiteral("files/%1").arg(relativePath));
            files.append(QJsonObject{
                {QStringLiteral("source"), source},
                {QStringLiteral("destination"), destination},
                {QStringLiteral("relativePath"), relativePath},
                {QStringLiteral("length"), static_cast<double>(info.size())},
                {
                    QStringLiteral("lastWriteTimeUtc"),
                    info.lastModified().toUTC().toString(Qt::ISODateWithMs),
                },
            });
            totalBytes += info.size();
        }

        return QJsonObject{
            {QStringLiteral("tempRoot"), tempRoot},
            {QStringLiteral("quarantineRoot"), quarantineRoot},
            {QStringLiteral("olderThanDays"), olderThanDays},
            {QStringLiteral("files"), files},
            {QStringLiteral("totalBytes"), static_cast<double>(totalBytes)},
            {QStringLiteral("skipped"), skipped},
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        QJsonArray moved;
        for (const QJsonValue &value : before.value(QStringLiteral("files")).toArray()) {
            const QJsonObject file = value.toObject();
            const QString source = file.value(QStringLiteral("source")).toString();
            const QString destination = file.value(QStringLiteral("destination")).toString();
            if (!QFileInfo::exists(source)) {
                continue;
            }
            if (QFileInfo::exists(destination)) {
                fail(QStringLiteral("Quarantine destination already exists: %1").arg(destination));
            }
            if (!moveFile(source, destination)) {
                fail(QStringLiteral("Unable to quarantine '%1'.").arg(source));
            }
            moved.append(file);
        }
        return QJsonObject{
            {QStringLiteral("moved"), moved},
            {QStringLiteral("movedCount"), moved.size()},
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        for (
            const QJsonValue &value :
            snapshot.value(QStringLiteral("after")).toObject()
                .value(QStringLiteral("moved")).toArray()
        ) {
            const QJsonObject file = value.toObject();
            if (
                QFileInfo::exists(file.value(QStringLiteral("source")).toString())
                || !QFileInfo::exists(file.value(QStringLiteral("destination")).toString())
            ) {
                return false;
            }
        }
        return true;
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonArray files = snapshot.value(QStringLiteral("after")).toObject()
            .value(QStringLiteral("moved")).toArray();
        for (const QJsonValue &value : files) {
            const QJsonObject file = value.toObject();
            const QString source = file.value(QStringLiteral("source")).toString();
            const QString destination = file.value(QStringLiteral("destination")).toString();
            if (!QFileInfo::exists(destination)) {
                continue;
            }
            if (QFileInfo::exists(source)) {
                fail(QStringLiteral("Cannot restore '%1' because the destination exists.").arg(source));
            }
            if (!moveFile(destination, source)) {
                fail(QStringLiteral("Unable to restore '%1'.").arg(source));
            }
        }
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        for (
            const QJsonValue &value :
            snapshot.value(QStringLiteral("after")).toObject()
                .value(QStringLiteral("moved")).toArray()
        ) {
            if (QFileInfo::exists(value.toObject().value(QStringLiteral("destination")).toString())) {
                return false;
            }
        }
        return true;
    }
};

QString resolveDeviceAffinityPath(const RuleOptions &options)
{
    const QString explicitPath = options.stringValue(QStringLiteral("RegistryPath"));
    if (!explicitPath.isEmpty()) {
        return explicitPath;
    }
    const QString instanceId = options.stringValue(QStringLiteral("InstanceId"));
    if (instanceId.isEmpty()) {
        fail(QStringLiteral("RegistryPath or InstanceId is required."));
    }
    const QString path = QStringLiteral(
        "HKLM\\SYSTEM\\CurrentControlSet\\Enum\\%1\\"
        "Device Parameters\\Interrupt Management\\Affinity Policy"
    ).arg(instanceId);
    if (!RegistryStore::keyExists(path)) {
        fail(QStringLiteral("Device instance '%1' was not found.").arg(instanceId));
    }
    return path;
}

quint64 cpuMaskValue(const QVariant &value)
{
    bool ok = false;
    const QString text = value.toString().trimmed();
    if (text.startsWith(QStringLiteral("0x"), Qt::CaseInsensitive)) {
        const quint64 result = text.mid(2).toULongLong(&ok, 16);
        if (ok) {
            return result;
        }
    }
    const quint64 result = text.toULongLong(&ok, 10);
    return ok ? result : 0;
}

class DeviceAffinityHandler final : public BaseHandler {
public:
    DeviceAffinityHandler()
        : BaseHandler(QStringLiteral("DeviceAffinity"))
    {
    }

    Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        try {
            resolveDeviceAffinityPath(options);
            return Requirement::available(QStringLiteral("The device affinity key is available."));
        } catch (const std::exception &exception) {
            return Requirement::unavailable(QString::fromUtf8(exception.what()));
        }
    }

    QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString path = resolveDeviceAffinityPath(options);
        return QJsonObject{
            {QStringLiteral("registryPath"), path},
            {
                QStringLiteral("policy"),
                RegistryStore::read(path, QStringLiteral("DevicePolicy")).toJson(),
            },
            {
                QStringLiteral("mask"),
                RegistryStore::read(path, QStringLiteral("AssignmentSetOverride")).toJson(),
            },
        };
    }

    QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(context);
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        const quint64 mask = cpuMaskValue(options.value(QStringLiteral("CpuMask")));
        if (mask == 0) {
            RegistryStore::remove(path, QStringLiteral("DevicePolicy"));
            RegistryStore::remove(path, QStringLiteral("AssignmentSetOverride"));
        } else {
            RegistryStore::write(
                path,
                QStringLiteral("DevicePolicy"),
                QStringLiteral("DWord"),
                4U
            );
            QByteArray bytes;
            for (int index = 0; index < 8; ++index) {
                bytes.append(static_cast<char>((mask >> (index * 8)) & 0xFFU));
            }
            RegistryStore::write(
                path,
                QStringLiteral("AssignmentSetOverride"),
                QStringLiteral("Binary"),
                bytes
            );
        }
        return QJsonObject{
            {
                QStringLiteral("policy"),
                RegistryStore::read(path, QStringLiteral("DevicePolicy")).toJson(),
            },
            {
                QStringLiteral("mask"),
                RegistryStore::read(path, QStringLiteral("AssignmentSetOverride")).toJson(),
            },
        };
    }

    bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QJsonObject after = snapshot.value(QStringLiteral("after")).toObject();
        return RegistryStore::equivalent(
                   RegistryStore::read(
                       before.value(QStringLiteral("registryPath")).toString(),
                       QStringLiteral("DevicePolicy")
                   ),
                   RegistryValue::fromJson(after.value(QStringLiteral("policy")).toObject())
               )
            && RegistryStore::equivalent(
                RegistryStore::read(
                    before.value(QStringLiteral("registryPath")).toString(),
                    QStringLiteral("AssignmentSetOverride")
                ),
                RegistryValue::fromJson(after.value(QStringLiteral("mask")).toObject())
            );
    }

    bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        return verifyApplied(rule, options, snapshot, context)
            || verifyRestored(rule, options, snapshot, context);
    }

    void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        restoreRegistryEntry(
            RegistryValue::fromJson(before.value(QStringLiteral("policy")).toObject()),
            path,
            QStringLiteral("DevicePolicy")
        );
        restoreRegistryEntry(
            RegistryValue::fromJson(before.value(QStringLiteral("mask")).toObject()),
            path,
            QStringLiteral("AssignmentSetOverride")
        );
    }

    bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const override
    {
        Q_UNUSED(rule);
        Q_UNUSED(options);
        Q_UNUSED(context);
        const QJsonObject before = snapshot.value(QStringLiteral("before")).toObject();
        const QString path = before.value(QStringLiteral("registryPath")).toString();
        return RegistryStore::equivalent(
                   RegistryStore::read(path, QStringLiteral("DevicePolicy")),
                   RegistryValue::fromJson(before.value(QStringLiteral("policy")).toObject())
               )
            && RegistryStore::equivalent(
                RegistryStore::read(path, QStringLiteral("AssignmentSetOverride")),
                RegistryValue::fromJson(before.value(QStringLiteral("mask")).toObject())
            );
    }
};

}  // namespace

void registerBuiltinHandlers(HandlerRegistry &registry)
{
    registry.add(
        QStringLiteral("RegistrySet"),
        std::make_shared<RegistrySetHandler>()
    );
    registry.add(
        QStringLiteral("PowerPlan"),
        std::make_shared<PowerPlanHandler>()
    );
    registry.add(
        QStringLiteral("ProcessorMinimum"),
        std::make_shared<PowerSettingHandler>(
            QStringLiteral("ProcessorMinimum"),
            QStringLiteral("Processor"),
            100
        )
    );
    registry.add(
        QStringLiteral("CoreParkingMinimum"),
        std::make_shared<PowerSettingHandler>(
            QStringLiteral("CoreParkingMinimum"),
            QStringLiteral("CoreParking"),
            100
        )
    );
    registry.add(
        QStringLiteral("CpuIdleDisable"),
        std::make_shared<PowerSettingHandler>(
            QStringLiteral("CpuIdleDisable"),
            QStringLiteral("CpuIdle"),
            1
        )
    );
    registry.add(
        QStringLiteral("UsbSelectiveSuspend"),
        std::make_shared<PowerSettingHandler>(
            QStringLiteral("UsbSelectiveSuspend"),
            QStringLiteral("Usb"),
            0
        )
    );
    registry.add(
        QStringLiteral("PcieAspm"),
        std::make_shared<PowerSettingHandler>(
            QStringLiteral("PcieAspm"),
            QStringLiteral("Pcie"),
            0
        )
    );
    registry.add(
        QStringLiteral("HeterogeneousPowerPolicy"),
        std::make_shared<HeterogeneousPowerPolicyHandler>()
    );
    registry.add(
        QStringLiteral("BcdTimers"),
        std::make_shared<BcdTimersHandler>()
    );
    registry.add(
        QStringLiteral("TcpAutotuning"),
        std::make_shared<TcpGlobalHandler>(
            QStringLiteral("TcpAutotuning"),
            true
        )
    );
    registry.add(
        QStringLiteral("TcpTimestamps"),
        std::make_shared<TcpGlobalHandler>(
            QStringLiteral("TcpTimestamps"),
            false
        )
    );
    registry.add(
        QStringLiteral("NicPower"),
        std::make_shared<NicPowerHandler>()
    );
    registry.add(
        QStringLiteral("NetworkInterruptModeration"),
        std::make_shared<NetworkInterruptModerationHandler>()
    );
    registry.add(
        QStringLiteral("DnsProfile"),
        std::make_shared<DnsProfileHandler>()
    );
    registry.add(
        QStringLiteral("AmdDynamicPstate"),
        std::make_shared<AmdDynamicPstateHandler>()
    );
    registry.add(
        QStringLiteral("ServiceState"),
        std::make_shared<ServiceStateHandler>()
    );
    registry.add(
        QStringLiteral("ServiceFixed"),
        std::make_shared<ServiceStateHandler>(QStringLiteral("ServiceFixed"))
    );
    registry.add(
        QStringLiteral("StartupItem"),
        std::make_shared<StartupItemHandler>()
    );
    registry.add(
        QStringLiteral("TempQuarantine"),
        std::make_shared<TempQuarantineHandler>()
    );
    registry.add(
        QStringLiteral("DeviceAffinity"),
        std::make_shared<DeviceAffinityHandler>()
    );

    registry.add(
        QStringLiteral("PrioritySeparation"),
        std::make_shared<SyntheticRegistrySetHandler>(
            QStringLiteral("PrioritySeparation"),
            QJsonArray{
                QJsonObject{
                    {
                        QStringLiteral("path"),
                        QStringLiteral(
                            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl"
                        ),
                    },
                    {QStringLiteral("name"), QStringLiteral("Win32PrioritySeparation")},
                    {QStringLiteral("kind"), QStringLiteral("DWord")},
                    {QStringLiteral("value"), 40},
                },
            }
        )
    );
    registry.add(
        QStringLiteral("MultimediaProfile"),
        std::make_shared<SyntheticRegistrySetHandler>(
            QStringLiteral("MultimediaProfile"),
            QJsonArray{
                QJsonObject{
                    {
                        QStringLiteral("path"),
                        QStringLiteral(
                            "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\"
                            "Multimedia\\SystemProfile"
                        ),
                    },
                    {QStringLiteral("name"), QStringLiteral("NetworkThrottlingIndex")},
                    {QStringLiteral("kind"), QStringLiteral("DWord")},
                    {QStringLiteral("value"), 4294967295.0},
                },
                QJsonObject{
                    {
                        QStringLiteral("path"),
                        QStringLiteral(
                            "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\"
                            "Multimedia\\SystemProfile"
                        ),
                    },
                    {QStringLiteral("name"), QStringLiteral("SystemResponsiveness")},
                    {QStringLiteral("kind"), QStringLiteral("DWord")},
                    {QStringLiteral("value"), 0},
                },
            }
        )
    );
}

}  // namespace felix::core
