#pragma once

#include "felix/core/rule_types.h"

#include <QHash>
#include <QList>
#include <QString>

namespace felix::core {

class RuleCatalog {
public:
    bool loadFromFile(const QString &filePath, QString *error = nullptr);
    bool loadFromJson(const QByteArray &json, QString *error = nullptr);

    [[nodiscard]] const QList<RuleDefinition> &rules() const;
    [[nodiscard]] const RuleDefinition *find(const QString &ruleId) const;
    [[nodiscard]] int size() const;

private:
    QList<RuleDefinition> m_rules;
    QHash<QString, int> m_indexById;
};

}  // namespace felix::core

