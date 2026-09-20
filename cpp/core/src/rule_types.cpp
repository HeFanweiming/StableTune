#include "felix/core/rule_types.h"

#include <QJsonArray>
#include <QJsonValue>
#include <QFileInfo>
#include <QRegularExpression>

#include <utility>

namespace felix::core {
namespace {

QStringList jsonStringList(const QJsonObject &object, const QString &key)
{
    QStringList values;
    for (const QJsonValue &value : object.value(key).toArray()) {
        if (value.isString()) {
            values.append(value.toString());
        }
    }
    return values;
}

QJsonValue variantToJson(const QVariant &value)
{
    if (!value.isValid() || value.isNull()) {
        return QJsonValue(QJsonValue::Null);
    }

    switch (value.metaType().id()) {
    case QMetaType::Bool:
        return value.toBool();
    case QMetaType::Int:
    case QMetaType::UInt:
    case QMetaType::LongLong:
    case QMetaType::ULongLong:
    case QMetaType::Double:
        return value.toDouble();
    case QMetaType::QStringList:
        return QJsonArray::fromStringList(value.toStringList());
    case QMetaType::QByteArray:
        return QString::fromLatin1(value.toByteArray().toBase64());
    default:
        return value.toString();
    }
}

QString templateText(const QVariant &value)
{
    if (!value.isValid() || value.isNull()) {
        return {};
    }
    if (value.metaType().id() == QMetaType::Bool) {
        return value.toBool() ? QStringLiteral("True") : QStringLiteral("False");
    }
    return value.toString();
}

}  // namespace

QString ruleRiskToString(RuleRisk risk)
{
    switch (risk) {
    case RuleRisk::Safe:
        return QStringLiteral("safe");
    case RuleRisk::Advanced:
        return QStringLiteral("advanced");
    case RuleRisk::Unknown:
        return QStringLiteral("unknown");
    }
    return QStringLiteral("unknown");
}

RuleRisk ruleRiskFromString(const QString &value)
{
    if (value.compare(QStringLiteral("safe"), Qt::CaseInsensitive) == 0) {
        return RuleRisk::Safe;
    }
    if (value.compare(QStringLiteral("advanced"), Qt::CaseInsensitive) == 0) {
        return RuleRisk::Advanced;
    }
    return RuleRisk::Unknown;
}

RuleDefinition RuleDefinition::fromJson(const QJsonObject &object, QString *error)
{
    RuleDefinition definition;
    definition.id = object.value(QStringLiteral("id")).toString().trimmed();
    definition.category = object.value(QStringLiteral("category")).toString().trimmed();
    definition.name = object.value(QStringLiteral("name")).toString().trimmed();
    definition.description = object.value(QStringLiteral("description")).toString();
    definition.risk = ruleRiskFromString(object.value(QStringLiteral("risk")).toString());
    definition.requiresAdmin = object.value(QStringLiteral("requiresAdmin")).toBool(true);
    definition.requiresRestart = object.value(QStringLiteral("requiresRestart")).toBool(false);
    definition.requiresInput = object.value(QStringLiteral("requiresInput")).toBool(false);
    definition.platform = object.value(QStringLiteral("platform")).toString();
    definition.prerequisites = jsonStringList(object, QStringLiteral("prerequisites"));
    definition.snapshotKind = object.value(QStringLiteral("snapshotKind")).toString();
    definition.handler = object.value(QStringLiteral("handler")).toString().trimmed();
    definition.raw = object;

    QStringList missing;
    if (definition.id.isEmpty()) {
        missing.append(QStringLiteral("id"));
    }
    if (definition.name.isEmpty()) {
        missing.append(QStringLiteral("name"));
    }
    if (definition.handler.isEmpty()) {
        missing.append(QStringLiteral("handler"));
    }

    if (!missing.isEmpty() && error != nullptr) {
        *error = QStringLiteral("Rule definition is missing required fields: %1")
                     .arg(missing.join(QStringLiteral(", ")));
    }
    return definition;
}

RuleOptions::RuleOptions(QVariantMap values)
    : m_values(std::move(values))
{
}

bool RuleOptions::contains(const QString &key) const
{
    return m_values.contains(key);
}

QVariant RuleOptions::value(const QString &key) const
{
    return m_values.value(key);
}

QString RuleOptions::stringValue(const QString &key, const QString &fallback) const
{
    const QVariant candidate = value(key);
    return candidate.isValid() && !candidate.isNull() ? candidate.toString() : fallback;
}

bool RuleOptions::boolValue(const QString &key, bool fallback) const
{
    const QVariant candidate = value(key);
    return candidate.isValid() && !candidate.isNull() ? candidate.toBool() : fallback;
}

int RuleOptions::intValue(const QString &key, int fallback) const
{
    bool ok = false;
    const int result = stringValue(key).toInt(&ok);
    return ok ? result : fallback;
}

QStringList RuleOptions::stringList(const QString &key) const
{
    const QVariant candidate = value(key);
    if (!candidate.isValid() || candidate.isNull()) {
        return {};
    }
    if (candidate.metaType().id() == QMetaType::QStringList) {
        return candidate.toStringList();
    }
    if (candidate.metaType().id() == QMetaType::QString) {
        return {candidate.toString()};
    }
    return {};
}

const QVariantMap &RuleOptions::values() const
{
    return m_values;
}

QHash<QString, QString> RuleOptions::templateValues() const
{
    QHash<QString, QString> values;
    for (auto iterator = m_values.cbegin(); iterator != m_values.cend(); ++iterator) {
        values.insert(iterator.key(), templateText(iterator.value()));
    }

    const QString executablePath = values.value(QStringLiteral("ExecutablePath"));
    if (!executablePath.isEmpty()) {
        values.insert(
            QStringLiteral("ExecutableName"),
            QFileInfo(executablePath).fileName()
        );
    }
    return values;
}

Requirement Requirement::available(QString message)
{
    return Requirement{true, std::move(message)};
}

Requirement Requirement::unavailable(QString message)
{
    return Requirement{false, std::move(message)};
}

OperationResult OperationResult::ok(QString status, QString message)
{
    OperationResult result;
    result.success = true;
    result.status = std::move(status);
    result.message = std::move(message);
    return result;
}

OperationResult OperationResult::fail(QString status, QString message)
{
    OperationResult result;
    result.success = false;
    result.status = std::move(status);
    result.message = std::move(message);
    return result;
}

}  // namespace felix::core
