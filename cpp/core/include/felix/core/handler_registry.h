#pragma once

#include "felix/core/rule_handler.h"

#include <QHash>
#include <QStringList>
#include <memory>

namespace felix::core {

class HandlerRegistry {
public:
    void add(const QString &handlerId, std::shared_ptr<IRuleHandler> handler);

    [[nodiscard]] bool contains(const QString &handlerId) const;
    [[nodiscard]] std::shared_ptr<IRuleHandler> handler(const QString &handlerId) const;
    [[nodiscard]] QStringList handlerIds() const;

private:
    QHash<QString, std::shared_ptr<IRuleHandler>> m_handlers;
};

void registerBuiltinHandlers(HandlerRegistry &registry);

}  // namespace felix::core

