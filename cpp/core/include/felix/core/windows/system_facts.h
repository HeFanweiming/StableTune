#pragma once

#include <QString>

namespace felix::core::windows {

class SystemFacts {
public:
    [[nodiscard]] static bool isAdministrator();
    [[nodiscard]] static bool antiCheatExpertPresent();
    [[nodiscard]] static bool hasSsd();
    [[nodiscard]] static bool isSsdDetectionAvailable();
};

}  // namespace felix::core::windows
