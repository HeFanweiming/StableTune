#include "felix/core/handler_registry.h"
#include "felix/core/rule_engine.h"
#include "felix/core/snapshot_repository.h"
#include "felix/bridge/powershell_bridge.h"

#include <QDir>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QTemporaryDir>
#include <QtTest>

using felix::core::HandlerRegistry;
using felix::core::OperationResult;
using felix::core::OperationContext;
using felix::core::RuleCatalog;
using felix::core::RuleEngine;
using felix::core::RuleOptions;
using felix::core::SnapshotRepository;
using felix::core::registerBuiltinHandlers;
using felix::bridge::PowerShellBridge;

class CoreTests final : public QObject {
    Q_OBJECT

private slots:
    void catalogLoadsAllRules()
    {
        RuleCatalog catalog;
        QString error;
        QVERIFY2(
            catalog.loadFromFile(QStringLiteral(FELIX_TEST_CATALOG), &error),
            qPrintable(error)
        );
        QCOMPARE(catalog.size(), 38);
        QVERIFY(catalog.find(QStringLiteral("power-plan")) != nullptr);
        QCOMPARE(
            catalog.find(QStringLiteral("power-plan"))->handler,
            QStringLiteral("PowerPlan")
        );
    }

    void everyRuleHasRegisteredHandler()
    {
        QString error;
        const std::unique_ptr<RuleEngine> engine = RuleEngine::createDefault(
            QStringLiteral(FELIX_TEST_CATALOG),
            QDir::tempPath(),
            &error
        );
        QVERIFY2(engine != nullptr, qPrintable(error));
        QStringList errors;
        QVERIFY2(engine->validateHandlers(&errors).isEmpty(), qPrintable(errors.join('\n')));
    }

    void builtinHandlerSetIsComplete()
    {
        HandlerRegistry registry;
        registerBuiltinHandlers(registry);
        QCOMPARE(registry.handlerIds().size(), 22);
        QVERIFY(registry.contains(QStringLiteral("RegistrySet")));
        QVERIFY(registry.contains(QStringLiteral("ServiceFixed")));
        QVERIFY(registry.contains(QStringLiteral("NetworkInterruptModeration")));
    }

    void everyRuleDryRunReturnsAResult()
    {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());

        QString error;
        const std::unique_ptr<RuleEngine> engine = RuleEngine::createDefault(
            QStringLiteral(FELIX_TEST_CATALOG),
            temporary.path(),
            &error
        );
        QVERIFY2(engine != nullptr, qPrintable(error));

        for (const auto &rule : engine->catalog().rules()) {
            OperationContext context;
            context.stateRoot = temporary.path();
            context.operationId = QStringLiteral("test-") + rule.id;
            const OperationResult result = engine->dryRun(
                rule.id,
                RuleOptions{},
                context
            );
            QVERIFY2(!result.status.isEmpty(), qPrintable(rule.id));
            QVERIFY2(!result.message.isEmpty(), qPrintable(rule.id));
            QCOMPARE(result.ruleId, rule.id);
        }
    }

    void snapshotRepositoryRoundTrips()
    {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());
        SnapshotRepository repository(temporary.path());
        const QJsonObject snapshot{
            {QStringLiteral("ruleId"), QStringLiteral("power-plan")},
            {QStringLiteral("value"), 42},
        };
        const auto write = repository.save(QStringLiteral("test-op"), snapshot);
        QVERIFY2(write.success, qPrintable(write.message));
        QVERIFY(repository.verify(write.path, write.sha256, nullptr));

        QJsonObject loaded;
        QVERIFY(repository.load(write.path, &loaded, nullptr));
        QCOMPARE(loaded.value(QStringLiteral("ruleId")).toString(), QStringLiteral("power-plan"));
        QCOMPARE(loaded.value(QStringLiteral("value")).toInt(), 42);
    }

    void powershellBridgeReturnsTheSameRuleCatalog()
    {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());

        PowerShellBridge bridge(
            QStringLiteral(FELIX_TEST_REPOSITORY),
            temporary.path()
        );
        const auto response = bridge.call(QStringLiteral("Get-FelixRule"));
        QVERIFY2(response.success, qPrintable(response.error));
        QVERIFY(response.data.isArray());
        const QJsonArray rules = response.data.toArray();
        QCOMPARE(rules.size(), 38);

        QStringList ids;
        for (const QJsonValue &value : rules) {
            ids.append(value.toObject().value(QStringLiteral("id")).toString());
        }
        ids.sort();
        QVERIFY(ids.contains(QStringLiteral("power-plan")));
        QVERIFY(ids.contains(QStringLiteral("process-priority-ace")));
        QCOMPARE(ids.size(), QSet<QString>(ids.cbegin(), ids.cend()).size());
    }

    void powershellBridgeMatchesNativeCatalogForAllRules()
    {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());

        RuleCatalog catalog;
        QString error;
        QVERIFY2(
            catalog.loadFromFile(QStringLiteral(FELIX_TEST_CATALOG), &error),
            qPrintable(error)
        );

        PowerShellBridge bridge(
            QStringLiteral(FELIX_TEST_REPOSITORY),
            temporary.path()
        );
        const auto response = bridge.call(QStringLiteral("Get-FelixRule"));
        QVERIFY2(response.success, qPrintable(response.error));

        QHash<QString, QJsonObject> backendRules;
        for (const QJsonValue &value : response.data.toArray()) {
            const QJsonObject rule = value.toObject();
            backendRules.insert(rule.value(QStringLiteral("id")).toString(), rule);
        }
        for (const auto &rule : catalog.rules()) {
            QVERIFY2(backendRules.contains(rule.id), qPrintable(rule.id));
            const QJsonObject backendRule = backendRules.value(rule.id);
            QCOMPARE(
                backendRule.value(QStringLiteral("name")).toString(),
                rule.name
            );
            QCOMPARE(
                backendRule.value(QStringLiteral("risk")).toString(),
                felix::core::ruleRiskToString(rule.risk)
            );
            QCOMPARE(
                backendRule.value(QStringLiteral("requiresInput")).toBool(),
                rule.requiresInput
            );
        }
    }

    void powershellBridgeProvidesReadOnlyInputCandidates()
    {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());

        PowerShellBridge bridge(
            QStringLiteral(FELIX_TEST_REPOSITORY),
            temporary.path()
        );

        const auto adapters = bridge.call(
            QStringLiteral("Get-FelixNetworkAdapterCandidates")
        );
        QVERIFY2(adapters.success, qPrintable(adapters.error));
        QVERIFY(adapters.data.isArray());
        if (!adapters.data.toArray().isEmpty()) {
            const QJsonObject adapter = adapters.data.toArray().first().toObject();
            QVERIFY(!adapter.value(QStringLiteral("Name")).toString().isEmpty());
        }

        const auto services = bridge.call(
            QStringLiteral("Get-FelixServiceCandidates")
        );
        QVERIFY2(services.success, qPrintable(services.error));
        QVERIFY(services.data.isArray());
        if (!services.data.toArray().isEmpty()) {
            const QJsonObject service = services.data.toArray().first().toObject();
            QVERIFY(!service.value(QStringLiteral("Name")).toString().isEmpty());
        }

        const auto statePath = bridge.call(QStringLiteral("Get-FelixStatePath"));
        QVERIFY2(statePath.success, qPrintable(statePath.error));
        QCOMPARE(
            QDir::cleanPath(statePath.data.toString()),
            QDir::cleanPath(temporary.path())
        );
    }
};

QTEST_MAIN(CoreTests)
#include "test_core.moc"
