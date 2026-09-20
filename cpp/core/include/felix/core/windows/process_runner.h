#pragma once

#include <QString>
#include <QStringList>

namespace felix::core::windows {

struct CommandResult {
    bool started = false;
    int exitCode = -1;
    QString standardOutput;
    QString standardError;
    QString error;

    [[nodiscard]] bool success() const;
    [[nodiscard]] QString combinedOutput() const;
};

class ProcessRunner {
public:
    static CommandResult run(
        const QString &program,
        const QStringList &arguments,
        int timeoutMs = 60000
    );

    static QString findExecutable(const QString &name);
};

}  // namespace felix::core::windows

