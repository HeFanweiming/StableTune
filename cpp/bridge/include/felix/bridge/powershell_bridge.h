#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>

namespace felix::bridge {

struct BridgeResponse {
    bool success = false;
    QJsonValue data;
    QString error;
    QByteArray standardError;
};

class PowerShellBridge {
public:
    PowerShellBridge(QString repositoryRoot, QString stateRoot = {});

    [[nodiscard]] BridgeResponse call(
        const QString &method,
        const QJsonObject &arguments = {},
        int timeoutMs = 300000
    ) const;

    [[nodiscard]] QString modulePath() const;
    [[nodiscard]] QString hostScriptPath() const;
    [[nodiscard]] const QString &repositoryRoot() const;
    [[nodiscard]] const QString &stateRoot() const;

    [[nodiscard]] static QString defaultRepositoryRoot();
    [[nodiscard]] static QString defaultStateRoot();
    [[nodiscard]] static QString findPowerShell();

private:
    QString m_repositoryRoot;
    QString m_stateRoot;
};

}  // namespace felix::bridge
