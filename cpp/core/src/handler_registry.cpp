#include "felix/core/handler_registry.h"

namespace felix::core {

void HandlerRegistry::add(const QString &handlerId, std::shared_ptr<IRuleHandler> handler)
{
    if (handlerId.isEmpty() || handler == nullptr) {
        return;
    }
    m_handlers.insert(handlerId, std::move(handler));
}

bool HandlerRegistry::contains(const QString &handlerId) const
{
    return m_handlers.contains(handlerId);
}

std::shared_ptr<IRuleHandler> HandlerRegistry::handler(const QString &handlerId) const
{
    return m_handlers.value(handlerId);
}

QStringList HandlerRegistry::handlerIds() const
{
    QStringList ids = m_handlers.keys();
    ids.sort();
    return ids;
}

}  // namespace felix::core

