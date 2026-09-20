#include "felix/core/windows/process_runner.h"

#include <QDir>
#include <QProcess>
#include <QStandardPaths>

namespace felix::core::windows {

bool CommandResult::success() const
{
    return started && exitCode == 0;
}

QString CommandResult::combinedOutput() const
{
    QStringList parts;
    if (!standardOutput.trimmed().isEmpty()) {
        parts.append(standardOutput.trimmed());
    }
    if (!standardError.trimmed().isEmpty()) {
        parts.append(standardError.trimmed());
    }
    if (!error.trimmed().isEmpty()) {
        parts.append(error.trimmed());
    }
    return parts.join(QLatin1Char('\n'));
}

CommandResult ProcessRunner::run(
    const QString &program,
    const QStringList &arguments,
    int timeoutMs
)
{
    CommandResult result;
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.start();

    if (!process.waitForStarted(10000)) {
        result.error = process.errorString();
        return result;
    }

    result.started = true;
    if (!process.waitForFinished(timeoutMs)) {
        process.kill();
        process.waitForFinished(5000);
        result.error = QStringLiteral("Command timed out after %1 ms.").arg(timeoutMs);
        return result;
    }

    result.exitCode = process.exitCode();
    result.standardOutput = QString::fromLocal8Bit(process.readAllStandardOutput());
    result.standardError = QString::fromLocal8Bit(process.readAllStandardError());
    if (process.exitStatus() != QProcess::NormalExit) {
        result.error = QStringLiteral("Command crashed.");
    }
    return result;
}

QString ProcessRunner::findExecutable(const QString &name)
{
    return QStandardPaths::findExecutable(name);
}

}  // namespace felix::core::windows
