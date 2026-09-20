#pragma once

#include "felix/core/handler_registry.h"
#include "felix/core/rule_catalog.h"
#include "felix/core/rule_types.h"
#include "felix/core/snapshot_repository.h"

#include <memory>

namespace felix::core {

class RuleEngine {
public:
    RuleEngine(RuleCatalog catalog, std::shared_ptr<HandlerRegistry> handlers);

    static std::unique_ptr<RuleEngine> createDefault(
        const QString &catalogPath,
        const QString &stateRoot,
        QString *error = nullptr
    );

    [[nodiscard]] const RuleCatalog &catalog() const;
    [[nodiscard]] QStringList validateHandlers(QStringList *errors = nullptr) const;

    [[nodiscard]] OperationResult dryRun(
        const QString &ruleId,
        const RuleOptions &options,
        OperationContext context
    ) const;

    [[nodiscard]] OperationResult apply(
        const QString &ruleId,
        const RuleOptions &options,
        bool acceptRisk,
        OperationContext context
    );

    [[nodiscard]] OperationResult restore(
        const RuleDefinition &rule,
        const RuleOptions &options,
        const QJsonObject &snapshot,
        bool force,
        OperationContext context
    );

private:
    [[nodiscard]] std::shared_ptr<IRuleHandler> requireHandler(
        const RuleDefinition &rule,
        QString *error
    ) const;

    RuleCatalog m_catalog;
    std::shared_ptr<HandlerRegistry> m_handlers;
    SnapshotRepository m_snapshots;
};

}  // namespace felix::core

