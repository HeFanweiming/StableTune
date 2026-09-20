#include "felix/core/snapshot_repository.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSaveFile>

namespace felix::core {
namespace {

QString safeOperationId(const QString &operationId)
{
    QString safe = operationId;
    safe.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    return safe.isEmpty() ? QStringLiteral("operation") : safe;
}

QByteArray fileHash(const QString &path, QString *error)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error != nullptr) {
            *error = file.errorString();
        }
        return {};
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file)) {
        if (error != nullptr) {
            *error = file.errorString();
        }
        return {};
    }
    return hash.result();
}

}  // namespace

SnapshotRepository::SnapshotRepository(QString stateRoot)
    : m_stateRoot(std::move(stateRoot))
{
}

SnapshotWriteResult SnapshotRepository::save(
    const QString &operationId,
    const QJsonObject &snapshot
) const
{
    SnapshotWriteResult result;
    if (m_stateRoot.isEmpty()) {
        result.message = QStringLiteral("Snapshot state root is empty.");
        return result;
    }

    QDir directory(snapshotDirectory());
    if (!directory.exists() && !directory.mkpath(QStringLiteral("."))) {
        result.message = QStringLiteral("Unable to create snapshot directory '%1'.")
                             .arg(directory.absolutePath());
        return result;
    }

    result.path = directory.filePath(safeOperationId(operationId) + QStringLiteral(".json"));
    QSaveFile file(result.path);
    if (!file.open(QIODevice::WriteOnly)) {
        result.message = QStringLiteral("Unable to write snapshot '%1': %2")
                             .arg(result.path, file.errorString());
        return result;
    }

    const QByteArray json = QJsonDocument(snapshot).toJson(QJsonDocument::Indented);
    if (file.write(json) != json.size() || !file.commit()) {
        result.message = QStringLiteral("Unable to finalize snapshot '%1': %2")
                             .arg(result.path, file.errorString());
        return result;
    }

    QString hashError;
    const QByteArray hash = fileHash(result.path, &hashError);
    if (hash.isEmpty()) {
        result.message = QStringLiteral("Unable to hash snapshot '%1': %2")
                             .arg(result.path, hashError);
        return result;
    }

    result.success = true;
    result.sha256 = QString::fromLatin1(hash.toHex()).toUpper();
    result.message = QStringLiteral("Snapshot saved.");
    return result;
}

bool SnapshotRepository::load(
    const QString &path,
    QJsonObject *snapshot,
    QString *error
) const
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error != nullptr) {
            *error = file.errorString();
        }
        return false;
    }

    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    if (!document.isObject()) {
        if (error != nullptr) {
            *error = QStringLiteral("Snapshot '%1' is not a JSON object.").arg(path);
        }
        return false;
    }

    if (snapshot != nullptr) {
        *snapshot = document.object();
    }
    return true;
}

bool SnapshotRepository::verify(
    const QString &path,
    const QString &expectedHash,
    QString *error
) const
{
    QString hashError;
    const QByteArray hash = fileHash(path, &hashError);
    if (hash.isEmpty()) {
        if (error != nullptr) {
            *error = hashError;
        }
        return false;
    }

    const QString actualHash = QString::fromLatin1(hash.toHex()).toUpper();
    if (actualHash.compare(expectedHash, Qt::CaseInsensitive) != 0) {
        if (error != nullptr) {
            *error = QStringLiteral("Snapshot hash mismatch. Expected %1, actual %2.")
                         .arg(expectedHash, actualHash);
        }
        return false;
    }
    return true;
}

const QString &SnapshotRepository::stateRoot() const
{
    return m_stateRoot;
}

QString SnapshotRepository::snapshotDirectory() const
{
    return QDir(m_stateRoot).filePath(QStringLiteral("snapshots"));
}

}  // namespace felix::core

