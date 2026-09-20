#include "felix/core/rule_engine.h"

#include <QDateTime>
#include <QJsonArray>
#include <QSet>
#include <QUuid>

namespace felix::core {
namespace {

QString effectiveOperationId(const QString &operationId)
{
    if (!operationId.trimmed().isEmpty()) {
        return operationId.trimmed();
    }
    return QStringLiteral("op-") + QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

RuleEngine::RuleEngine(RuleCatalog catalog, std::shared_ptr<HandlerRegistry> handlers)
    : m_catalog(std::move(catalog))
    , m_handlers(std::move(handlers))
{
}

std::unique_ptr<RuleEngine> RuleEngine::createDefault(
    const QString &catalogPath,
    const QString &stateRoot,
    QString *error
)
{
    RuleCatalog catalog;
    if (!catalog.loadFromFile(catalogPath, error)) {
        return nullptr;
    }

    auto handlers = std::make_shared<HandlerRegistry>();
    registerBuiltinHandlers(*handlers);

    auto engine = std::make_unique<RuleEngine>(std::move(catalog), std::move(handlers));
    engine->m_snapshots = SnapshotRepository(stateRoot);

    QStringList validationErrors;
    const QStringList missingHandlers = engine->validateHandlers(&validationErrors);
    if (!missingHandlers.isEmpty()) {
        if (error != nullptr) {
            *error = validationErrors.isEmpty()
                ? QStringLiteral("Rules reference unregistered handlers: %1")
                      .arg(missingHandlers.join(QStringLiteral(", ")))
                : validationErrors.join(QStringLiteral("\n"));
        }
        return nullptr;
    }
    return engine;
}

const RuleCatalog &RuleEngine::catalog() const
{
    return m_catalog;
}

QStringList RuleEngine::validateHandlers(QStringList *errors) const
{
    QSet<QString> missing;
    for (const RuleDefinition &rule : m_catalog.rules()) {
        if (!m_handlers->contains(rule.handler)) {
            missing.insert(rule.handler);
            if (errors != nullptr) {
                errors->append(
                    QStringLiteral("Rule '%1' references missing handler '%2'.")
                        .arg(rule.id, rule.handler)
                );
            }
        }
    }

    QStringList values = missing.values();
    values.sort();
    return values;
}

OperationResult RuleEngine::dryRun(
    const QString &ruleId,
    const RuleOptions &options,
    OperationContext context
) const
{
    const RuleDefinition *rule = m_catalog.find(ruleId);
    if (rule == nullptr) {
        return OperationResult::fail(
            QStringLiteral("not_found"),
            QStringLiteral("Rule '%1' was not found.").arg(ruleId)
        );
    }

    QString handlerError;
    const std::shared_ptr<IRuleHandler> handler = requireHandler(*rule, &handlerError);
    if (handler == nullptr) {
        return OperationResult::fail(QStringLiteral("handler_missing"), handlerError);
    }

    context.dryRun = true;
    const Requirement requirement = handler->check(*rule, options, context);
    OperationResult result = requirement.isAvailable
        ? OperationResult::ok(QStringLiteral("ready"), requirement.message)
        : OperationResult::fail(QStringLiteral("blocked"), requirement.message);
    result.ruleId = rule->id;

    QJsonObject details{
        {QStringLiteral("handler"), rule->handler},
        {QStringLiteral("risk"), ruleRiskToString(rule->risk)},
        {QStringLiteral("available"), requirement.isAvailable},
        {QStringLiteral("requirement"), requirement.message},
    };

    if (requirement.isAvailable) {
        try {
            result.snapshot = QJsonObject{
                {QStringLiteral("before"), handler->snapshot(*rule, options, context)},
            };
            details.insert(QStringLiteral("snapshotReadable"), true);
        } catch (const std::exception &exception) {
            result.success = false;
            result.status = QStringLiteral("snapshot_failed");
            result.message = QString::fromUtf8(exception.what());
            details.insert(QStringLiteral("snapshotReadable"), false);
        }
    }

    result.details = details;
    return result;
}

OperationResult RuleEngine::apply(
    const QString &ruleId,
    const RuleOptions &options,
    bool acceptRisk,
    OperationContext context
)
{
    const RuleDefinition *rule = m_catalog.find(ruleId);
    if (rule == nullptr) {
        return OperationResult::fail(
            QStringLiteral("not_found"),
            QStringLiteral("Rule '%1' was not found.").arg(ruleId)
        );
    }
    if (rule->risk == RuleRisk::Advanced && !acceptRisk) {
        return OperationResult::fail(
            QStringLiteral("risk_not_accepted"),
            QStringLiteral("Advanced rule '%1' requires explicit risk acceptance.").arg(ruleId)
        );
    }

    QString handlerError;
    const std::shared_ptr<IRuleHandler> handler = requireHandler(*rule, &handlerError);
    if (handler == nullptr) {
        return OperationResult::fail(QStringLiteral("handler_missing"), handlerError);
    }

    context.dryRun = false;
    context.operationId = effectiveOperationId(context.operationId);

    const Requirement requirement = handler->check(*rule, options, context);
    if (!requirement.isAvailable) {
        return OperationResult::fail(QStringLiteral("blocked"), requirement.message);
    }

    QJsonObject snapshot;
    bool mutationStarted = false;
    try {
        snapshot = QJsonObject{
            {QStringLiteral("schemaVersion"), QStringLiteral("2.0")},
            {QStringLiteral("ruleId"), rule->id},
            {QStringLiteral("handler"), rule->handler},
            {QStringLiteral("operationId"), context.operationId},
            {QStringLiteral("createdAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
            {QStringLiteral("phase"), QStringLiteral("before_apply")},
            {QStringLiteral("before"), handler->snapshot(*rule, options, context)},
        };

        const SnapshotWriteResult preWrite = m_snapshots.save(context.operationId, snapshot);
        if (!preWrite.success) {
            return OperationResult::fail(QStringLiteral("snapshot_failed"), preWrite.message);
        }

        mutationStarted = true;
        snapshot.insert(
            QStringLiteral("after"),
            handler->apply(*rule, options, snapshot.value(QStringLiteral("before")).toObject(), context)
        );
        snapshot.insert(QStringLiteral("phase"), QStringLiteral("applied"));
        snapshot.insert(QStringLiteral("appliedAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));

        if (!handler->verifyApplied(*rule, options, snapshot, context)) {
            handler->restore(*rule, options, snapshot, context);
            return OperationResult::fail(
                QStringLiteral("verify_failed"),
                QStringLiteral("Rule '%1' was applied but verification failed. Rollback was attempted.")
                    .arg(rule->id)
            );
        }

        const SnapshotWriteResult finalWrite = m_snapshots.save(context.operationId, snapshot);
        if (!finalWrite.success) {
            QString rollbackError;
            try {
                handler->restore(*rule, options, snapshot, context);
                if (!handler->verifyRestored(*rule, options, snapshot, context)) {
                    rollbackError = QStringLiteral("Restore verification failed.");
                }
            } catch (const std::exception &exception) {
                rollbackError = QString::fromUtf8(exception.what());
            }

            return OperationResult::fail(
                rollbackError.isEmpty()
                    ? QStringLiteral("snapshot_commit_failed_rolled_back")
                    : QStringLiteral("snapshot_commit_failed_rollback_failed"),
                rollbackError.isEmpty()
                    ? QStringLiteral(
                          "Rule '%1' was rolled back because the final snapshot could not be committed: %2"
                      ).arg(rule->id, finalWrite.message)
                    : QStringLiteral(
                          "Rule '%1' could not commit its final snapshot and rollback failed: %2"
                      ).arg(rule->id, rollbackError)
            );
        }

        OperationResult result = OperationResult::ok(
            QStringLiteral("applied"),
            QStringLiteral("Rule '%1' applied and verified.").arg(rule->name)
        );
        result.ruleId = rule->id;
        result.historyId = context.operationId;
        result.snapshot = snapshot;
        result.snapshotPath = finalWrite.path;
        result.snapshotHash = finalWrite.sha256;
        return result;
    } catch (const std::exception &exception) {
        QString rollbackError;
        if (mutationStarted && !snapshot.isEmpty()) {
            try {
                handler->restore(*rule, options, snapshot, context);
                if (!handler->verifyRestored(*rule, options, snapshot, context)) {
                    rollbackError = QStringLiteral("Restore verification failed.");
                }
            } catch (const std::exception &rollbackException) {
                rollbackError = QString::fromUtf8(rollbackException.what());
            }
        }

        const QString applyError = QString::fromUtf8(exception.what());
        return OperationResult::fail(
            rollbackError.isEmpty()
                ? QStringLiteral("apply_failed_rolled_back")
                : QStringLiteral("apply_failed_rollback_failed"),
            rollbackError.isEmpty()
                ? QStringLiteral("Rule '%1' failed and was rolled back: %2")
                      .arg(rule->id, applyError)
                : QStringLiteral(
                      "Rule '%1' failed (%2), and rollback failed: %3"
                  ).arg(rule->id, applyError, rollbackError)
        );
    }
}

OperationResult RuleEngine::restore(
    const RuleDefinition &rule,
    const RuleOptions &options,
    const QJsonObject &snapshot,
    bool force,
    OperationContext context
)
{
    context.dryRun = false;
    QString handlerError;
    const std::shared_ptr<IRuleHandler> handler = requireHandler(rule, &handlerError);
    if (handler == nullptr) {
        return OperationResult::fail(QStringLiteral("handler_missing"), handlerError);
    }
    if (!force && !handler->hasRestoreConflict(rule, options, snapshot, context)) {
        return OperationResult::fail(
            QStringLiteral("restore_conflict"),
            QStringLiteral("Restore was blocked because the current state no longer matches the saved operation.")
        );
    }

    try {
        handler->restore(rule, options, snapshot, context);
        if (!handler->verifyRestored(rule, options, snapshot, context)) {
            return OperationResult::fail(
                QStringLiteral("restore_verify_failed"),
                QStringLiteral("Rule '%1' restore verification failed.").arg(rule.name)
            );
        }

        OperationResult result = OperationResult::ok(
            QStringLiteral("restored"),
            QStringLiteral("Rule '%1' restored and verified.").arg(rule.name)
        );
        result.ruleId = rule.id;
        result.snapshot = snapshot;
        return result;
    } catch (const std::exception &exception) {
        return OperationResult::fail(
            QStringLiteral("restore_failed"),
            QString::fromUtf8(exception.what())
        );
    }
}

std::shared_ptr<IRuleHandler> RuleEngine::requireHandler(
    const RuleDefinition &rule,
    QString *error
) const
{
    const std::shared_ptr<IRuleHandler> handler = m_handlers->handler(rule.handler);
    if (handler == nullptr && error != nullptr) {
        *error = QStringLiteral("Rule '%1' references missing handler '%2'.")
                     .arg(rule.id, rule.handler);
    }
    return handler;
}

}  // namespace felix::core
