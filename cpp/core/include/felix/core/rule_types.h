#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantMap>

namespace felix::core {

enum class RuleRisk {
    Safe,
    Advanced,
    Unknown,
};

QString ruleRiskToString(RuleRisk risk);
RuleRisk ruleRiskFromString(const QString &value);

struct RuleDefinition {
    QString id;
    QString category;
    QString name;
    QString description;
    RuleRisk risk = RuleRisk::Unknown;
    bool requiresAdmin = true;
    bool requiresRestart = false;
    bool requiresInput = false;
    QString platform;
    QStringList prerequisites;
    QString snapshotKind;
    QString handler;
    QJsonObject raw;

    static RuleDefinition fromJson(const QJsonObject &object, QString *error = nullptr);
};

class RuleOptions {
public:
    RuleOptions() = default;
    explicit RuleOptions(QVariantMap values);

    [[nodiscard]] bool contains(const QString &key) const;
    [[nodiscard]] QVariant value(const QString &key) const;
    [[nodiscard]] QString stringValue(const QString &key, const QString &fallback = {}) const;
    [[nodiscard]] bool boolValue(const QString &key, bool fallback = false) const;
    [[nodiscard]] int intValue(const QString &key, int fallback = 0) const;
    [[nodiscard]] QStringList stringList(const QString &key) const;
    [[nodiscard]] const QVariantMap &values() const;
    [[nodiscard]] QHash<QString, QString> templateValues() const;

private:
    QVariantMap m_values;
};

struct OperationContext {
    QString operationId;
    QString stateRoot;
    bool dryRun = false;
};

struct Requirement {
    bool isAvailable = false;
    QString message;

    static Requirement available(QString message = {});
    static Requirement unavailable(QString message);
};

struct OperationResult {
    bool success = false;
    QString status;
    QString message;
    QString ruleId;
    QString historyId;
    QString snapshotPath;
    QString snapshotHash;
    QJsonObject snapshot;
    QJsonObject details;

    static OperationResult ok(QString status, QString message);
    static OperationResult fail(QString status, QString message);
};

}  // namespace felix::core
