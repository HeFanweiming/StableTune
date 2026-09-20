#pragma once

#include "felix/core/rule_types.h"

#include <QJsonObject>

namespace felix::core {

class IRuleHandler {
public:
    virtual ~IRuleHandler() = default;

    [[nodiscard]] virtual QString id() const = 0;
    [[nodiscard]] virtual Requirement check(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const = 0;

    [[nodiscard]] virtual QJsonObject snapshot(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const OperationContext &context
    ) const = 0;

    [[nodiscard]] virtual QJsonObject apply(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &before,
        const OperationContext &context
    ) = 0;

    [[nodiscard]] virtual bool verifyApplied(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const = 0;

    [[nodiscard]] virtual bool hasRestoreConflict(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const = 0;

    virtual void restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) = 0;

    [[nodiscard]] virtual bool verifyRestored(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        const OperationContext &context
    ) const = 0;
};

}  // namespace felix::core

