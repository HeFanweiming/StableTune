#pragma once

#include <QJsonObject>
#include <QString>

namespace felix::core {

struct SnapshotWriteResult {
    bool success = false;
    QString path;
    QString sha256;
    QString message;
};

class SnapshotRepository {
public:
    explicit SnapshotRepository(QString stateRoot = {});

    [[nodiscard]] SnapshotWriteResult save(const QString &operationId, const QJsonObject &snapshot) const;
    [[nodiscard]] bool load(const QString &path, QJsonObject *snapshot, QString *error = nullptr) const;
    [[nodiscard]] bool verify(
        const QString &path,
        const QString &expectedHash,
        QString *error = nullptr
    ) const;

    [[nodiscard]] const QString &stateRoot() const;
    [[nodiscard]] QString snapshotDirectory() const;

private:
    QString m_stateRoot;
};

}  // namespace felix::core

