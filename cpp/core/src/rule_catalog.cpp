#include "felix/core/rule_catalog.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QSet>

namespace felix::core {

bool RuleCatalog::loadFromFile(const QString &filePath, QString *error)
{
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error != nullptr) {
            *error = QStringLiteral("Unable to open rule catalog '%1': %2")
                         .arg(filePath, file.errorString());
        }
        return false;
    }
    return loadFromJson(file.readAll(), error);
}

bool RuleCatalog::loadFromJson(const QByteArray &json, QString *error)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error != nullptr) {
            *error = QStringLiteral("Invalid rule catalog JSON at offset %1: %2")
                         .arg(parseError.offset)
                         .arg(parseError.errorString());
        }
        return false;
    }

    const QJsonArray rules = document.object().value(QStringLiteral("rules")).toArray();
    QList<RuleDefinition> parsedRules;
    QHash<QString, int> index;
    parsedRules.reserve(rules.size());

    for (const QJsonValue &value : rules) {
        if (!value.isObject()) {
            if (error != nullptr) {
                *error = QStringLiteral("Rule catalog contains a non-object rule entry.");
            }
            return false;
        }

        QString ruleError;
        const RuleDefinition definition = RuleDefinition::fromJson(value.toObject(), &ruleError);
        if (!ruleError.isEmpty()) {
            if (error != nullptr) {
                *error = ruleError;
            }
            return false;
        }
        if (index.contains(definition.id)) {
            if (error != nullptr) {
                *error = QStringLiteral("Duplicate rule id '%1'.").arg(definition.id);
            }
            return false;
        }

        index.insert(definition.id, parsedRules.size());
        parsedRules.append(definition);
    }

    m_rules = std::move(parsedRules);
    m_indexById = std::move(index);
    return true;
}

const QList<RuleDefinition> &RuleCatalog::rules() const
{
    return m_rules;
}

const RuleDefinition *RuleCatalog::find(const QString &ruleId) const
{
    const auto iterator = m_indexById.constFind(ruleId);
    if (iterator == m_indexById.cend()) {
        return nullptr;
    }
    return &m_rules.at(iterator.value());
}

int RuleCatalog::size() const
{
    return m_rules.size();
}

}  // namespace felix::core

