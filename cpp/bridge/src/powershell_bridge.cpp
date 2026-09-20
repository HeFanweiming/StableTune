#include "felix/bridge/powershell_bridge.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStandardPaths>

namespace felix::bridge {
namespace {

QString firstExistingFile(const QStringList &candidates)
{
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo::exists(candidate)) {
            return QFileInfo(candidate).absoluteFilePath();
        }
    }
    return {};
}

QString applicationDirectory()
{
    return QCoreApplication::applicationDirPath();
}

}  // namespace

PowerShellBridge::PowerShellBridge(QString repositoryRoot, QString stateRoot)
    : m_repositoryRoot(std::move(repositoryRoot))
    , m_stateRoot(std::move(stateRoot))
{
}

BridgeResponse PowerShellBridge::call(
    const QString &method,
    const QJsonObject &arguments,
    int timeoutMs
) const
{
    BridgeResponse response;
    const QString powershell = findPowerShell();
    if (powershell.isEmpty()) {
        response.error = QStringLiteral(
            "PowerShell 7 was not found. Install PowerShell 7.4 or set FELIX_POWERSHELL."
        );
        return response;
    }

    const QString module = modulePath();
    if (module.isEmpty()) {
        response.error = QStringLiteral("StableTune PowerShell module was not found.");
        return response;
    }

    const QString host = hostScriptPath();
    if (host.isEmpty()) {
        response.error = QStringLiteral("StableTune backend host was not found.");
        return response;
    }

    QProcess process;
    process.setProgram(powershell);
    process.setArguments({
        QStringLiteral("-NoLogo"),
        QStringLiteral("-NoProfile"),
        QStringLiteral("-NonInteractive"),
        QStringLiteral("-ExecutionPolicy"),
        QStringLiteral("Bypass"),
        QStringLiteral("-File"),
        host,
        QStringLiteral("-ModulePath"),
        module,
    });
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.setWorkingDirectory(m_repositoryRoot);

    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    if (!m_stateRoot.isEmpty()) {
        environment.insert(QStringLiteral("FELIX_OPTIMIZER_HOME"), m_stateRoot);
    }
    process.setProcessEnvironment(environment);

    const QJsonObject request{
        {QStringLiteral("method"), method},
        {QStringLiteral("arguments"), arguments},
    };
    process.start();
    if (!process.waitForStarted(15000)) {
        response.error = QStringLiteral("Unable to start PowerShell: %1")
                             .arg(process.errorString());
        return response;
    }

    const QByteArray requestJson = QJsonDocument(request).toJson(QJsonDocument::Compact);
    if (process.write(requestJson) != requestJson.size()) {
        process.kill();
        process.waitForFinished();
        response.error = QStringLiteral("Unable to send the backend request.");
        return response;
    }
    process.closeWriteChannel();

    if (!process.waitForFinished(timeoutMs)) {
        process.kill();
        process.waitForFinished();
        response.error = QStringLiteral("Backend method '%1' timed out.").arg(method);
        response.standardError = process.readAllStandardError();
        return response;
    }

    const QByteArray standardOutput = process.readAllStandardOutput().trimmed();
    response.standardError = process.readAllStandardError().trimmed();
    if (process.exitStatus() != QProcess::NormalExit) {
        response.error = QStringLiteral("PowerShell backend crashed.");
        return response;
    }

    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(standardOutput, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        response.error = QStringLiteral("Invalid backend response for '%1': %2")
                             .arg(method, parseError.errorString());
        if (!response.standardError.isEmpty()) {
            response.error += QStringLiteral("\n%1")
                                  .arg(QString::fromLocal8Bit(response.standardError));
        }
        return response;
    }

    const QJsonObject object = document.object();
    response.success = object.value(QStringLiteral("success")).toBool(false);
    response.data = object.value(QStringLiteral("data"));
    if (!response.success) {
        response.error = object.value(QStringLiteral("error"))
                             .toString(QStringLiteral("Unknown backend error."));
    }
    return response;
}

QString PowerShellBridge::modulePath() const
{
    const QString appDirectory = applicationDirectory();
    return firstExistingFile({
        QDir(appDirectory).filePath(
            QStringLiteral("powershell/StableTune/StableTune.psd1")
        ),
        QDir(appDirectory).filePath(
            QStringLiteral("../powershell/StableTune/StableTune.psd1")
        ),
        QDir(m_repositoryRoot).filePath(
            QStringLiteral("src/StableTune/StableTune.psd1")
        ),
    });
}

QString PowerShellBridge::hostScriptPath() const
{
    const QString appDirectory = applicationDirectory();
    return firstExistingFile({
        QDir(appDirectory).filePath(QStringLiteral("powershell/backend_host.ps1")),
        QDir(appDirectory).filePath(QStringLiteral("../powershell/backend_host.ps1")),
        QDir(m_repositoryRoot).filePath(
            QStringLiteral("cpp/backend/backend_host.ps1")
        ),
    });
}

const QString &PowerShellBridge::repositoryRoot() const
{
    return m_repositoryRoot;
}

const QString &PowerShellBridge::stateRoot() const
{
    return m_stateRoot;
}

QString PowerShellBridge::defaultRepositoryRoot()
{
    const QString appDirectory = applicationDirectory();
    const QStringList candidates{
        appDirectory,
        QDir(appDirectory).filePath(QStringLiteral("../..")),
        QDir(appDirectory).filePath(QStringLiteral("../../..")),
        QDir::currentPath(),
    };
    for (const QString &candidate : candidates) {
        const QFileInfo module(
            QDir(candidate).filePath(QStringLiteral("src/StableTune/StableTune.psd1"))
        );
        if (module.isFile()) {
            QDir repository(module.absolutePath());
            repository.cdUp();
            repository.cdUp();
            return repository.absolutePath();
        }
    }
    return QDir::currentPath();
}

QString PowerShellBridge::defaultStateRoot()
{
    const QString override = qEnvironmentVariable("FELIX_OPTIMIZER_HOME");
    if (!override.isEmpty()) {
        return QDir::cleanPath(override);
    }
    QString localAppData = qEnvironmentVariable("LOCALAPPDATA");
    if (localAppData.isEmpty()) {
        localAppData = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    }
    if (localAppData.isEmpty()) {
        localAppData = QDir(QStandardPaths::writableLocation(QStandardPaths::HomeLocation))
                           .filePath(QStringLiteral("AppData/Local"));
    }
    return QDir(localAppData).filePath(QStringLiteral("FelixOptimizer"));
}

QString PowerShellBridge::findPowerShell()
{
    const QString override = qEnvironmentVariable("FELIX_POWERSHELL");
    if (!override.isEmpty() && QFileInfo::exists(override)) {
        return QFileInfo(override).absoluteFilePath();
    }

    const QString path = QStandardPaths::findExecutable(QStringLiteral("pwsh"));
    if (!path.isEmpty()) {
        return path;
    }

    const QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    const QString programFiles = environment.value(QStringLiteral("ProgramFiles"));
    const QString programFilesX86 = environment.value(QStringLiteral("ProgramFiles(x86)"));
    const QString localAppData = environment.value(QStringLiteral("LOCALAPPDATA"));
    const QString userProfile = environment.value(QStringLiteral("USERPROFILE"));
    const QString chocolatey = environment.value(
        QStringLiteral("ChocolateyInstall"),
        QStringLiteral("C:/ProgramData/chocolatey")
    );
    const QString home = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);

    const QStringList candidates{
        QDir(programFiles).filePath(QStringLiteral("PowerShell/7/pwsh.exe")),
        QDir(programFiles).filePath(QStringLiteral("PowerShell/7-preview/pwsh.exe")),
        QDir(programFilesX86).filePath(QStringLiteral("PowerShell/7/pwsh.exe")),
        QDir(localAppData).filePath(QStringLiteral("Microsoft/WindowsApps/pwsh.exe")),
        QDir(localAppData).filePath(QStringLiteral("Microsoft/PowerShell/7/pwsh.exe")),
        QDir(localAppData).filePath(QStringLiteral("Programs/PowerShell/7/pwsh.exe")),
        QDir(userProfile).filePath(
            QStringLiteral(
                ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/"
                "powershell/pwsh.exe"
            )
        ),
        QDir(userProfile).filePath(QStringLiteral("scoop/apps/pwsh/current/pwsh.exe")),
        QDir(chocolatey).filePath(QStringLiteral("bin/pwsh.exe")),
        QDir(home).filePath(QStringLiteral(".local/bin/pwsh.exe")),
    };
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo::exists(candidate)) {
            return QFileInfo(candidate).absoluteFilePath();
        }
    }

    const QStringList roots{
        programFiles,
        programFilesX86,
        localAppData,
    };
    for (const QString &root : roots) {
        if (root.isEmpty()) {
            continue;
        }
        const QString candidate = QDir(root).filePath(QStringLiteral("PowerShell/7/pwsh.exe"));
        if (QFileInfo::exists(candidate)) {
            return QFileInfo(candidate).absoluteFilePath();
        }
    }
    return {};
}

}  // namespace felix::bridge
