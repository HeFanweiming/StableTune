#include "felix/bridge/powershell_bridge.h"

#include <QApplication>
#include <QButtonGroup>
#include <QCheckBox>
#include <QColor>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QFrame>
#include <QFutureWatcher>
#include <QGridLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QRegularExpression>
#include <QScrollArea>
#include <QSet>
#include <QSplitter>
#include <QStandardPaths>
#include <QStyle>
#include <QTableWidget>
#include <QTextCursor>
#include <QTextEdit>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <QVBoxLayout>
#include <QtConcurrent>

#include <algorithm>
#include <cmath>
#include <utility>

namespace {

using felix::bridge::BridgeResponse;
using felix::bridge::PowerShellBridge;

constexpr qint64 kGibiByte = 1024LL * 1024LL * 1024LL;

QJsonValue valueFor(const QJsonObject &object, const QString &name)
{
    const QJsonValue direct = object.value(name);
    if (!direct.isUndefined()) {
        return direct;
    }
    for (auto iterator = object.constBegin(); iterator != object.constEnd(); ++iterator) {
        if (iterator.key().compare(name, Qt::CaseInsensitive) == 0) {
            return iterator.value();
        }
    }
    return {};
}

QString scalarText(const QJsonValue &value)
{
    if (value.isString()) {
        return value.toString();
    }
    if (value.isBool()) {
        return value.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    }
    if (value.isDouble()) {
        const double number = value.toDouble();
        if (std::floor(number) == number) {
            return QString::number(static_cast<qint64>(number));
        }
        return QString::number(number, 'g', 15);
    }
    if (value.isNull() || value.isUndefined()) {
        return {};
    }
    return {};
}

QString stringFor(const QJsonObject &object, const QString &name)
{
    return scalarText(valueFor(object, name));
}

int intFor(const QJsonObject &object, const QString &name, int fallback = 0)
{
    const QJsonValue value = valueFor(object, name);
    if (value.isDouble()) {
        return value.toInt(fallback);
    }
    if (value.isString()) {
        bool ok = false;
        const int parsed = value.toString().toInt(&ok);
        return ok ? parsed : fallback;
    }
    return fallback;
}

double doubleFor(const QJsonObject &object, const QString &name, double fallback = 0.0)
{
    const QJsonValue value = valueFor(object, name);
    if (value.isDouble()) {
        return value.toDouble(fallback);
    }
    if (value.isString()) {
        bool ok = false;
        const double parsed = value.toString().toDouble(&ok);
        return ok ? parsed : fallback;
    }
    return fallback;
}

bool boolFor(const QJsonObject &object, const QString &name, bool fallback = false)
{
    const QJsonValue value = valueFor(object, name);
    if (value.isBool()) {
        return value.toBool();
    }
    if (value.isDouble()) {
        return value.toInt() != 0;
    }
    if (value.isString()) {
        const QString text = value.toString().trimmed();
        if (text.compare(QStringLiteral("true"), Qt::CaseInsensitive) == 0
            || text == QStringLiteral("1")
            || text.compare(QStringLiteral("yes"), Qt::CaseInsensitive) == 0) {
            return true;
        }
        if (text.compare(QStringLiteral("false"), Qt::CaseInsensitive) == 0
            || text == QStringLiteral("0")
            || text.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0) {
            return false;
        }
    }
    return fallback;
}

QJsonArray arrayFor(const QJsonObject &object, const QString &name)
{
    const QJsonValue value = valueFor(object, name);
    if (value.isArray()) {
        return value.toArray();
    }
    if (value.isObject()) {
        return QJsonArray{value};
    }
    return {};
}

QJsonArray asArray(const QJsonValue &value)
{
    if (value.isArray()) {
        return value.toArray();
    }
    if (value.isObject()) {
        return QJsonArray{value};
    }
    return {};
}

QJsonObject asObject(const QJsonValue &value)
{
    return value.isObject() ? value.toObject() : QJsonObject{};
}

QString jsonList(const QJsonArray &array, const QString &separator)
{
    QStringList values;
    values.reserve(array.size());
    for (const QJsonValue &value : array) {
        if (value.isObject()) {
            const QJsonObject object = value.toObject();
            const QString text = stringFor(object, QStringLiteral("message"));
            values.append(
                text.isEmpty() ? QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact))
                               : text
            );
        } else {
            values.append(scalarText(value));
        }
    }
    return values.join(separator);
}

QString formatDateTime(const QString &value)
{
    if (value.isEmpty()) {
        return {};
    }
    const QDateTime parsed = QDateTime::fromString(value, Qt::ISODateWithMs);
    if (parsed.isValid()) {
        return parsed.toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    const QDateTime fallback = QDateTime::fromString(value, Qt::ISODate);
    return fallback.isValid()
        ? fallback.toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"))
        : value;
}

QString roundedGigabytes(qint64 bytes, int decimals)
{
    if (bytes <= 0) {
        return {};
    }
    const double value = static_cast<double>(bytes) / static_cast<double>(kGibiByte);
    return QString::number(value, 'f', decimals);
}

void clearLayout(QLayout *layout)
{
    if (layout == nullptr) {
        return;
    }
    while (QLayoutItem *item = layout->takeAt(0)) {
        if (QWidget *widget = item->widget()) {
            delete widget;
            delete item;
        } else if (QLayout *child = item->layout()) {
            clearLayout(child);
            delete child;
        } else {
            delete item;
        }
    }
}

QFrame *separator()
{
    auto *line = new QFrame;
    line->setObjectName(QStringLiteral("separator"));
    line->setFrameShape(QFrame::HLine);
    line->setFixedHeight(1);
    return line;
}

QPushButton *commandButton(
    const QString &text,
    const QString &variant = QStringLiteral("secondary"),
    const QString &iconName = {}
)
{
    auto *button = new QPushButton(text);
    button->setProperty("variant", variant);
    button->setCursor(Qt::PointingHandCursor);
    button->setMinimumHeight(32);
    if (!iconName.isEmpty()) {
        if (iconName == QStringLiteral("refresh")) {
            button->setIcon(button->style()->standardIcon(QStyle::SP_BrowserReload));
        } else if (iconName == QStringLiteral("folder")) {
            button->setIcon(button->style()->standardIcon(QStyle::SP_DirOpenIcon));
        }
    }
    return button;
}

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(
        QString uiResourcePath,
        QString repositoryRoot,
        QString stateRoot,
        QString screenshotPath = {},
        bool smokeTest = false,
        QString initialPage = QStringLiteral("overview")
    )
        : m_bridge(std::move(repositoryRoot), std::move(stateRoot))
        , m_uiResourcePath(std::move(uiResourcePath))
        , m_screenshotPath(std::move(screenshotPath))
        , m_smokeTest(smokeTest)
    {
        setWindowTitle(QStringLiteral("稳优 StableTune"));
        resize(1280, 780);
        setMinimumSize(980, 640);

        if (!loadUiText()) {
            return;
        }

        buildShell();
        loadRuleDefinitions();
        showPage(initialPage);

        if (!m_screenshotPath.isEmpty()) {
            scheduleScreenshot();
        }
    }

    bool isReady() const
    {
        return !m_text.isEmpty() && m_ruleDefinitions.size() == 38;
    }

    QString startupError() const
    {
        return m_startupError;
    }

    bool runSmokeChecks()
    {
        if (!isReady()) {
            m_startupError = QStringLiteral("规则目录或 UI 资源未完整加载。");
            return false;
        }
        if (m_navButtons.size() != 7) {
            m_startupError = QStringLiteral("导航页面数量不是 7。");
            return false;
        }
        const BridgeResponse policy = m_bridge.call(QStringLiteral("Get-FelixRollbackPolicy"), {}, 30000);
        if (!policy.success) {
            m_startupError = policy.error;
            return false;
        }
        return true;
    }

private:
    bool loadUiText()
    {
        QFile file(m_uiResourcePath);
        if (!file.open(QIODevice::ReadOnly)) {
            m_startupError = QStringLiteral("无法读取 UI 资源：%1").arg(m_uiResourcePath);
            return false;
        }
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            m_startupError = QStringLiteral("UI 资源 JSON 无效：%1").arg(parseError.errorString());
            return false;
        }
        m_text = document.object();
        return true;
    }

    QString t(const QString &path, const QString &fallback = {}) const
    {
        QJsonValue current(m_text);
        const QStringList segments = path.split(QLatin1Char('.'), Qt::SkipEmptyParts);
        for (const QString &segment : segments) {
            if (!current.isObject()) {
                return fallback.isEmpty() ? path : fallback;
            }
            current = valueFor(current.toObject(), segment);
        }
        const QString text = scalarText(current);
        return text.isEmpty() ? (fallback.isEmpty() ? path : fallback) : text;
    }

    void buildShell()
    {
        auto *root = new QWidget;
        root->setObjectName(QStringLiteral("root"));
        setCentralWidget(root);

        auto *shell = new QHBoxLayout(root);
        shell->setContentsMargins(0, 0, 0, 0);
        shell->setSpacing(0);
        shell->addWidget(buildSidebar());

        auto *main = new QWidget;
        main->setObjectName(QStringLiteral("main"));
        auto *mainLayout = new QVBoxLayout(main);
        mainLayout->setContentsMargins(26, 22, 26, 18);
        mainLayout->setSpacing(0);

        m_pageTitle = new QLabel;
        m_pageTitle->setObjectName(QStringLiteral("pageTitle"));
        m_pageSubtitle = new QLabel;
        m_pageSubtitle->setObjectName(QStringLiteral("pageSubtitle"));
        m_pageSubtitle->setWordWrap(true);
        mainLayout->addWidget(m_pageTitle);
        mainLayout->addWidget(m_pageSubtitle);
        mainLayout->addSpacing(16);

        auto *pageScroll = new QScrollArea;
        pageScroll->setObjectName(QStringLiteral("pageScroll"));
        pageScroll->setWidgetResizable(true);
        pageScroll->setFrameShape(QFrame::NoFrame);
        m_pageHost = new QWidget;
        m_pageHost->setObjectName(QStringLiteral("pageHost"));
        m_pageLayout = new QVBoxLayout(m_pageHost);
        m_pageLayout->setContentsMargins(0, 0, 0, 0);
        m_pageLayout->setSpacing(12);
        pageScroll->setWidget(m_pageHost);
        mainLayout->addWidget(pageScroll, 1);

        auto *footer = new QFrame;
        footer->setObjectName(QStringLiteral("footer"));
        auto *footerLayout = new QHBoxLayout(footer);
        footerLayout->setContentsMargins(12, 8, 12, 8);
        m_status = new QLabel(t(QStringLiteral("app.statusReady"), QStringLiteral("就绪")));
        m_status->setObjectName(QStringLiteral("statusText"));
        m_status->setWordWrap(true);
        footerLayout->addWidget(m_status, 1);
        mainLayout->addSpacing(10);
        mainLayout->addWidget(footer);

        shell->addWidget(main, 1);
        setStyleSheet(styleSheetText());
    }

    QWidget *buildSidebar()
    {
        auto *sidebar = new QFrame;
        sidebar->setObjectName(QStringLiteral("sidebar"));
        sidebar->setFixedWidth(224);
        auto *layout = new QVBoxLayout(sidebar);
        layout->setContentsMargins(18, 22, 18, 18);
        layout->setSpacing(5);

        auto *brandMark = new QLabel(QStringLiteral("F"));
        brandMark->setObjectName(QStringLiteral("brandMark"));
        brandMark->setAlignment(Qt::AlignCenter);
        brandMark->setFixedSize(38, 38);
        layout->addWidget(brandMark);

        auto *brand = new QLabel(t(QStringLiteral("app.title"), QStringLiteral("稳优 StableTune")));
        brand->setObjectName(QStringLiteral("brandTitle"));
        brand->setWordWrap(true);
        layout->addWidget(brand);

        auto *subtitle = new QLabel(
            t(QStringLiteral("app.subtitle"), QStringLiteral("可回滚的系统优化原型"))
        );
        subtitle->setObjectName(QStringLiteral("brandSubtitle"));
        subtitle->setWordWrap(true);
        layout->addWidget(subtitle);
        layout->addSpacing(22);

        auto *navGroup = new QButtonGroup(this);
        navGroup->setExclusive(true);
        const QList<QPair<QString, QString>> pages{
            {QStringLiteral("overview"), t(QStringLiteral("nav.overview"))},
            {QStringLiteral("rules"), t(QStringLiteral("nav.rules"))},
            {QStringLiteral("history"), t(QStringLiteral("nav.history"))},
            {QStringLiteral("restore"), t(QStringLiteral("nav.restore"))},
            {QStringLiteral("logs"), t(QStringLiteral("nav.logs"))},
            {QStringLiteral("settings"), t(QStringLiteral("nav.settings"))},
            {QStringLiteral("about"), t(QStringLiteral("nav.about"))},
        };
        for (const auto &page : pages) {
            auto *button = new QPushButton(page.second);
            button->setObjectName(QStringLiteral("navButton"));
            button->setCheckable(true);
            button->setCursor(Qt::PointingHandCursor);
            button->setMinimumHeight(38);
            button->setProperty("page", page.first);
            connect(button, &QPushButton::clicked, this, [this, page] {
                showPage(page.first);
            });
            navGroup->addButton(button);
            layout->addWidget(button);
            m_navButtons.insert(page.first, button);
        }

        layout->addStretch(1);
        auto *badge = new QLabel(
            QStringLiteral("PowerShell 后端\n规则：38\nQt 6 Widgets")
        );
        badge->setObjectName(QStringLiteral("backendBadge"));
        badge->setWordWrap(true);
        layout->addWidget(badge);
        return sidebar;
    }

    void loadRuleDefinitions()
    {
        const BridgeResponse response = m_bridge.call(QStringLiteral("Get-FelixRule"), {}, 60000);
        if (!response.success) {
            m_startupError = response.error;
            return;
        }
        m_ruleDefinitions = asArray(response.data);
        for (const QJsonValue &value : m_ruleDefinitions) {
            const QJsonObject rule = value.toObject();
            m_ruleById.insert(stringFor(rule, QStringLiteral("id")), rule);
        }
    }

    void showPage(const QString &page)
    {
        ++m_pageVersion;
        m_currentPage = page;
        if (QPushButton *button = m_navButtons.value(page, nullptr)) {
            button->setChecked(true);
        }
        clearPage();

        if (page == QStringLiteral("overview")) {
            buildOverviewPage(m_pageVersion);
        } else if (page == QStringLiteral("rules")) {
            buildRulesPage(m_pageVersion);
        } else if (page == QStringLiteral("history")) {
            buildHistoryPage(m_pageVersion);
        } else if (page == QStringLiteral("restore")) {
            buildRestorePage(m_pageVersion);
        } else if (page == QStringLiteral("logs")) {
            buildLogsPage(m_pageVersion);
        } else if (page == QStringLiteral("settings")) {
            buildSettingsPage(m_pageVersion);
        } else if (page == QStringLiteral("about")) {
            buildAboutPage(m_pageVersion);
        }
    }

    void clearPage()
    {
        m_metricValues.clear();
        m_hardwareLayout = nullptr;
        m_changeNotice = nullptr;
        m_safetyNotice = nullptr;
        m_ruleFilter = nullptr;
        m_ruleTable = nullptr;
        m_ruleDetails = nullptr;
        m_restoreTable = nullptr;
        clearLayout(m_pageLayout);
    }

    void setPageHeader(const QString &title, const QString &subtitle)
    {
        m_pageTitle->setText(title);
        m_pageSubtitle->setText(subtitle);
        m_pageSubtitle->setVisible(!subtitle.isEmpty());
    }

    void setStatus(const QString &message)
    {
        m_status->setText(message);
    }

    BridgeResponse callBlocking(
        const QString &method,
        const QJsonObject &arguments = {},
        int timeoutMs = 300000
    )
    {
        setStatus(QStringLiteral("正在执行：%1").arg(method));
        QApplication::setOverrideCursor(Qt::WaitCursor);
        BridgeResponse response = m_bridge.call(method, arguments, timeoutMs);
        QApplication::restoreOverrideCursor();
        return response;
    }

    template <typename Handler>
    void callAsync(
        const QString &method,
        const QJsonObject &arguments,
        Handler handler,
        int timeoutMs = 300000
    )
    {
        auto *watcher = new QFutureWatcher<BridgeResponse>(this);
        ++m_pendingCalls;
        connect(
            watcher,
            &QFutureWatcher<BridgeResponse>::finished,
            this,
            [this, watcher, handler = std::move(handler)]() mutable {
                BridgeResponse response = watcher->result();
                watcher->deleteLater();
                --m_pendingCalls;
                handler(response);
            }
        );
        watcher->setFuture(QtConcurrent::run(
            [bridge = m_bridge, method, arguments, timeoutMs] {
                return bridge.call(method, arguments, timeoutMs);
            }
        ));
    }

    void showError(const QString &title, const QString &message)
    {
        QMessageBox::critical(this, title, message);
    }

    void showInformation(const QString &title, const QString &message)
    {
        QMessageBox::information(this, title, message);
    }

    bool confirm(
        const QString &title,
        const QString &message,
        QMessageBox::Icon icon = QMessageBox::Question
    )
    {
        QMessageBox box(icon, title, message, QMessageBox::Yes | QMessageBox::No, this);
        box.setDefaultButton(QMessageBox::No);
        return box.exec() == QMessageBox::Yes;
    }

    QString categoryName(const QString &category) const
    {
        return t(QStringLiteral("categories.%1").arg(category), category);
    }

    QString statusText(const QString &status) const
    {
        if (status == QStringLiteral("NotApplied")) {
            return t(QStringLiteral("rules.notApplied"));
        }
        if (status == QStringLiteral("Applied")) {
            return t(QStringLiteral("rules.applied"));
        }
        if (status == QStringLiteral("Restored")) {
            return t(QStringLiteral("rules.restored"));
        }
        if (status == QStringLiteral("InProgress")) {
            return t(QStringLiteral("rules.inProgress"));
        }
        if (status == QStringLiteral("Restoring")) {
            return t(QStringLiteral("rules.restoring"));
        }
        if (status == QStringLiteral("RestoreFailed") || status == QStringLiteral("Failed")) {
            return t(QStringLiteral("rules.failed"));
        }
        if (status == QStringLiteral("CrashRecovered")) {
            return t(QStringLiteral("rules.crashRecovered"));
        }
        if (status == QStringLiteral("CrashRecoveryFailed")) {
            return t(QStringLiteral("rules.crashRecoveryFailed"));
        }
        return status;
    }

    QString systemStateText(const QString &state) const
    {
        if (state == QStringLiteral("Modified")) {
            return t(QStringLiteral("rules.modified"));
        }
        if (state == QStringLiteral("NotModified")) {
            return t(QStringLiteral("rules.notModified"));
        }
        if (state == QStringLiteral("RequiresSelection")) {
            return t(QStringLiteral("rules.requiresSelection"));
        }
        if (state == QStringLiteral("NotPersistent")) {
            return t(QStringLiteral("rules.notPersistent"));
        }
        return t(QStringLiteral("rules.checkUnavailable"));
    }

    QString riskText(const QString &risk) const
    {
        return risk == QStringLiteral("safe")
            ? t(QStringLiteral("rules.riskLow"))
            : t(QStringLiteral("rules.riskHigh"));
    }

    void addMetric(const QString &key, const QString &label, const QString &value)
    {
        const int metricIndex = m_metricValues.size();
        auto *metric = new QWidget;
        metric->setObjectName(QStringLiteral("metric"));
        auto *layout = new QVBoxLayout(metric);
        layout->setContentsMargins(0, 0, 18, 14);
        layout->setSpacing(3);
        auto *labelWidget = new QLabel(label);
        labelWidget->setObjectName(QStringLiteral("metricLabel"));
        auto *valueWidget = new QLabel(value);
        valueWidget->setObjectName(QStringLiteral("metricValue"));
        valueWidget->setWordWrap(true);
        layout->addWidget(labelWidget);
        layout->addWidget(valueWidget);
        m_metricValues.insert(key, valueWidget);
        m_overviewMetricsLayout->addWidget(metric, metricIndex / 4, metricIndex % 4);
    }

    void setMetric(const QString &key, const QString &value)
    {
        if (QLabel *label = m_metricValues.value(key, nullptr)) {
            label->setText(value);
        }
    }

    void buildOverviewPage(int pageVersion)
    {
        setPageHeader(
            t(QStringLiteral("nav.overview")),
            t(QStringLiteral("app.subtitle"))
        );

        auto *metrics = new QWidget;
        metrics->setObjectName(QStringLiteral("metrics"));
        m_overviewMetricsLayout = new QGridLayout(metrics);
        m_overviewMetricsLayout->setContentsMargins(0, 0, 0, 8);
        m_overviewMetricsLayout->setHorizontalSpacing(14);
        m_overviewMetricsLayout->setVerticalSpacing(0);
        addMetric(QStringLiteral("os"), t(QStringLiteral("overview.os")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("admin"), t(QStringLiteral("overview.admin")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("power"), t(QStringLiteral("overview.power")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("rollback"), t(QStringLiteral("overview.rollback")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("crash"), t(QStringLiteral("overview.crashInsurance")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("snapshot"), t(QStringLiteral("overview.snapshot")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("systemRestorePoint"), t(QStringLiteral("overview.systemRestorePoint")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("modified"), t(QStringLiteral("overview.modifiedCount")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("clear"), t(QStringLiteral("overview.clearCount")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("selection"), t(QStringLiteral("overview.selectionCount")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("history"), t(QStringLiteral("overview.history")), t(QStringLiteral("overview.loading")));
        addMetric(QStringLiteral("pending"), t(QStringLiteral("overview.pending")), t(QStringLiteral("overview.loading")));
        m_pageLayout->addWidget(metrics);

        auto *hardwareTitle = new QLabel(t(QStringLiteral("overview.hardwareTitle")));
        hardwareTitle->setObjectName(QStringLiteral("sectionTitle"));
        m_pageLayout->addWidget(hardwareTitle);
        auto *hardwareHost = new QWidget;
        m_hardwareLayout = new QVBoxLayout(hardwareHost);
        m_hardwareLayout->setContentsMargins(0, 0, 0, 4);
        m_hardwareLayout->setSpacing(4);
        auto *hardwareLoading = new QLabel(t(QStringLiteral("overview.hardwareLoading")));
        hardwareLoading->setObjectName(QStringLiteral("mutedText"));
        m_hardwareLayout->addWidget(hardwareLoading);
        m_pageLayout->addWidget(hardwareHost);

        m_changeNotice = new QLabel(t(QStringLiteral("overview.systemChangesLoading")));
        m_changeNotice->setObjectName(QStringLiteral("noticeText"));
        m_changeNotice->setWordWrap(true);
        m_pageLayout->addWidget(m_changeNotice);

        m_safetyNotice = new QLabel(t(QStringLiteral("overview.safetyLoading")));
        m_safetyNotice->setObjectName(QStringLiteral("mutedText"));
        m_safetyNotice->setWordWrap(true);
        m_pageLayout->addWidget(m_safetyNotice);
        m_pageLayout->addStretch(1);

        if (m_smokeTest) {
            return;
        }

        callAsync(
            QStringLiteral("Get-FelixSystemStatus"),
            QJsonObject{{QStringLiteral("force"), true}},
            [this, pageVersion](const BridgeResponse &response) {
                if (!pageIsCurrent(pageVersion, QStringLiteral("overview"))) {
                    return;
                }
                if (!response.success) {
                    setStatus(response.error);
                    return;
                }
                updateOverviewStatus(asObject(response.data));
            },
            180000
        );
        callAsync(
            QStringLiteral("Get-FelixHardwareInventory"),
            QJsonObject{{QStringLiteral("force"), true}},
            [this, pageVersion](const BridgeResponse &response) {
                if (!pageIsCurrent(pageVersion, QStringLiteral("overview"))) {
                    return;
                }
                if (!response.success) {
                    setStatus(response.error);
                    return;
                }
                renderHardware(asObject(response.data));
            },
            180000
        );
        callAsync(
            QStringLiteral("Get-FelixSystemChangeReport"),
            {},
            [this, pageVersion](const BridgeResponse &response) {
                if (!pageIsCurrent(pageVersion, QStringLiteral("overview"))) {
                    return;
                }
                if (!response.success) {
                    setStatus(response.error);
                    return;
                }
                updateChangeReport(asObject(response.data));
            },
            180000
        );
        callAsync(
            QStringLiteral("Get-FelixCrashRecoveryStatus"),
            {},
            [this, pageVersion](const BridgeResponse &response) {
                if (!pageIsCurrent(pageVersion, QStringLiteral("overview"))) {
                    return;
                }
                if (!response.success) {
                    setStatus(response.error);
                    return;
                }
                updateCrashRecovery(asObject(response.data));
            },
            180000
        );
    }

    bool pageIsCurrent(int pageVersion, const QString &page) const
    {
        return pageVersion == m_pageVersion && m_currentPage == page;
    }

    void updateOverviewStatus(const QJsonObject &status)
    {
        const bool independent = stringFor(status, QStringLiteral("rollbackMode"))
            == QStringLiteral("IndependentSnapshot");
        const bool rollbackAvailable = boolFor(status, QStringLiteral("rollbackAvailable"));
        setMetric(QStringLiteral("os"), stringFor(status, QStringLiteral("os")));
        setMetric(
            QStringLiteral("admin"),
            boolFor(status, QStringLiteral("isAdministrator"))
                ? QStringLiteral("Yes")
                : QStringLiteral("No")
        );
        setMetric(QStringLiteral("power"), stringFor(status, QStringLiteral("activePowerPlan")));
        setMetric(
            QStringLiteral("rollback"),
            independent
                ? (rollbackAvailable ? t(QStringLiteral("overview.snapshotOnlyReady"))
                                     : t(QStringLiteral("overview.rollbackUnavailable")))
                : (rollbackAvailable ? t(QStringLiteral("overview.rollbackReady"))
                                     : t(QStringLiteral("overview.rollbackUnavailable")))
        );
        setMetric(
            QStringLiteral("snapshot"),
            boolFor(status, QStringLiteral("snapshotAvailable"))
                ? t(QStringLiteral("overview.rollbackReady"))
                : t(QStringLiteral("overview.rollbackUnavailable"))
        );
        setMetric(
            QStringLiteral("systemRestorePoint"),
            independent
                ? t(QStringLiteral("overview.restorePointNotRequired"))
                : (boolFor(status, QStringLiteral("restorePointAvailable"))
                       ? t(QStringLiteral("overview.restorePointReady"))
                       : t(QStringLiteral("overview.restorePointUnavailable")))
        );
        setMetric(QStringLiteral("history"), QString::number(intFor(status, QStringLiteral("historyCount"))));
        setMetric(QStringLiteral("pending"), QString::number(intFor(status, QStringLiteral("restorableCount"))));

        const QJsonObject crash = asObject(valueFor(status, QStringLiteral("crashRecovery")));
        if (!crash.isEmpty()) {
            updateCrashRecovery(crash);
        }

        if (m_safetyNotice != nullptr) {
            QStringList lines;
            if (independent) {
                lines.append(
                    rollbackAvailable ? t(QStringLiteral("dialogs.snapshotOnlyReady"))
                                      : t(QStringLiteral("dialogs.rollbackUnavailable"))
                );
            } else {
                lines.append(
                    rollbackAvailable ? t(QStringLiteral("dialogs.rollbackReady"))
                                      : t(QStringLiteral("dialogs.rollbackUnavailable"))
                );
            }
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("overview.crashInsurance")),
                        stringFor(crash, QStringLiteral("message"))
                    )
            );
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("overview.snapshot")),
                        boolFor(status, QStringLiteral("snapshotAvailable"))
                            ? t(QStringLiteral("overview.rollbackReady"))
                            : t(QStringLiteral("overview.rollbackUnavailable"))
                    )
            );
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("overview.systemRestorePoint")),
                        independent
                            ? t(QStringLiteral("overview.restorePointNotRequired"))
                            : (boolFor(status, QStringLiteral("restorePointAvailable"))
                                   ? t(QStringLiteral("overview.restorePointReady"))
                                   : t(QStringLiteral("overview.restorePointUnavailable")))
                    )
            );
            lines.append(stringFor(status, QStringLiteral("rollbackMessage")));
            if (independent) {
                lines.append(t(QStringLiteral("dialogs.snapshotOnlyWarning")));
            }
            m_safetyNotice->setText(lines.join(QLatin1Char('\n')));
            m_safetyNotice->setProperty("state", rollbackAvailable ? QStringLiteral("good") : QStringLiteral("bad"));
            m_safetyNotice->style()->unpolish(m_safetyNotice);
            m_safetyNotice->style()->polish(m_safetyNotice);
        }
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void updateCrashRecovery(const QJsonObject &crash)
    {
        const int manual = intFor(crash, QStringLiteral("manualCount"));
        const int active = intFor(crash, QStringLiteral("activeCount"));
        QString value;
        if (manual > 0) {
            value = t(QStringLiteral("rules.crashRecoveryFailed"));
        } else if (active > 0) {
            value = QStringLiteral("%1 / %2")
                        .arg(active)
                        .arg(t(QStringLiteral("overview.crashPending")));
        } else {
            value = t(QStringLiteral("overview.crashReady"));
        }
        setMetric(QStringLiteral("crash"), value);
    }

    void updateChangeReport(const QJsonObject &report)
    {
        const int modified = intFor(report, QStringLiteral("modified"));
        const int notModified = intFor(report, QStringLiteral("notModified"));
        const int selection = intFor(report, QStringLiteral("requiresSelection"));
        setMetric(QStringLiteral("modified"), QString::number(modified));
        setMetric(QStringLiteral("clear"), QString::number(notModified));
        setMetric(QStringLiteral("selection"), QString::number(selection));
        if (m_changeNotice != nullptr) {
            m_changeNotice->setText(
                QStringLiteral("%1: %2 / %3 (%4: %5, %6: %7, %8: %9)")
                    .arg(
                        t(QStringLiteral("overview.systemChanges")),
                        QString::number(modified),
                        QString::number(intFor(report, QStringLiteral("total"))),
                        t(QStringLiteral("overview.modifiedCount")),
                        QString::number(modified),
                        t(QStringLiteral("overview.clearCount")),
                        QString::number(notModified),
                        t(QStringLiteral("overview.selectionCount")),
                        QString::number(selection)
                    )
            );
        }
    }

    void addHardwareLine(const QString &label, const QString &value)
    {
        if (m_hardwareLayout == nullptr) {
            return;
        }
        auto *line = new QLabel(QStringLiteral("%1: %2").arg(label, value));
        line->setWordWrap(true);
        line->setObjectName(QStringLiteral("bodyText"));
        m_hardwareLayout->addWidget(line);
    }

    void renderHardware(const QJsonObject &hardware)
    {
        if (m_hardwareLayout == nullptr) {
            return;
        }
        clearLayout(m_hardwareLayout);

        const QJsonArray cpus = arrayFor(hardware, QStringLiteral("cpu"));
        QStringList cpuLines;
        for (const QJsonValue &value : cpus) {
            const QJsonObject cpu = value.toObject();
            cpuLines.append(
                QStringLiteral("%1 / %2C%3T")
                    .arg(
                        stringFor(cpu, QStringLiteral("name")),
                        QString::number(intFor(cpu, QStringLiteral("cores"))),
                        QString::number(intFor(cpu, QStringLiteral("logicalProcessors")))
                    )
            );
        }

        const QJsonArray gpus = arrayFor(hardware, QStringLiteral("gpu"));
        QStringList gpuLines;
        for (const QJsonValue &value : gpus) {
            const QJsonObject gpu = value.toObject();
            gpuLines.append(
                QStringLiteral("%1 / %2")
                    .arg(
                        stringFor(gpu, QStringLiteral("name")),
                        stringFor(gpu, QStringLiteral("driverVersion"))
                    )
            );
        }

        const QJsonArray disks = arrayFor(hardware, QStringLiteral("disks"));
        QStringList diskLines;
        for (const QJsonValue &value : disks) {
            const QJsonObject disk = value.toObject();
            const qint64 size = static_cast<qint64>(doubleFor(disk, QStringLiteral("sizeBytes")));
            diskLines.append(
                size > 0
                    ? QStringLiteral("%1 / %2 GB")
                          .arg(
                              stringFor(disk, QStringLiteral("model")),
                              QString::number(size / kGibiByte)
                          )
                    : stringFor(disk, QStringLiteral("model"))
            );
        }

        QString deviceSecurityText = t(QStringLiteral("overview.deviceSecurityUnavailable"));
        const QJsonValue deviceSecurityValue = valueFor(hardware, QStringLiteral("deviceSecurity"));
        if (deviceSecurityValue.isObject()) {
            const QJsonObject security = deviceSecurityValue.toObject();
            QString hvci;
            const QJsonValue hvciValue = valueFor(security, QStringLiteral("hvciRunning"));
            if (hvciValue.isBool()) {
                hvci = hvciValue.toBool() ? QStringLiteral("HVCI 运行中")
                                           : QStringLiteral("HVCI 未运行");
            } else {
                hvci = QStringLiteral("HVCI 状态未知");
            }
            deviceSecurityText = QStringLiteral("%1 / %2 / %3")
                                     .arg(
                                         stringFor(security, QStringLiteral("vbsStatusText")),
                                         hvci,
                                         stringFor(security, QStringLiteral("message"))
                                     );
        }

        addHardwareLine(
            t(QStringLiteral("overview.computer")),
            QStringLiteral("%1 %2 [%3]")
                .arg(
                    stringFor(hardware, QStringLiteral("manufacturer")),
                    stringFor(hardware, QStringLiteral("model")),
                    stringFor(hardware, QStringLiteral("computer"))
                )
        );
        addHardwareLine(
            t(QStringLiteral("overview.cpu")),
            cpuLines.isEmpty() ? t(QStringLiteral("overview.hardwareUnavailable"))
                               : cpuLines.join(QStringLiteral("; "))
        );
        addHardwareLine(
            t(QStringLiteral("overview.gpu")),
            gpuLines.isEmpty() ? t(QStringLiteral("overview.hardwareUnavailable"))
                               : gpuLines.join(QStringLiteral("; "))
        );
        addHardwareLine(
            t(QStringLiteral("overview.memory")),
            stringFor(hardware, QStringLiteral("memorySummary"))
        );
        addHardwareLine(
            t(QStringLiteral("overview.motherboard")),
            stringFor(hardware, QStringLiteral("motherboard"))
        );
        addHardwareLine(
            t(QStringLiteral("overview.disks")),
            diskLines.isEmpty() ? t(QStringLiteral("overview.hardwareUnavailable"))
                                : diskLines.join(QStringLiteral("; "))
        );
        addHardwareLine(t(QStringLiteral("overview.deviceSecurity")), deviceSecurityText);
        addHardwareLine(
            t(QStringLiteral("overview.acePresence")),
            boolFor(hardware, QStringLiteral("antiCheatExpertInstalled"))
                ? t(QStringLiteral("overview.aceDetected"))
                : t(QStringLiteral("overview.aceNotDetected"))
        );

        auto *memoryTitle = new QLabel(t(QStringLiteral("overview.memoryModules")));
        memoryTitle->setObjectName(QStringLiteral("subsectionTitle"));
        m_hardwareLayout->addSpacing(8);
        m_hardwareLayout->addWidget(memoryTitle);

        const QJsonArray memory = arrayFor(hardware, QStringLiteral("memory"));
        int timingCount = 0;
        for (const QJsonValue &value : memory) {
            const QJsonObject module = value.toObject();
            QString moduleName = stringFor(module, QStringLiteral("deviceLocator"));
            if (moduleName.isEmpty()) {
                moduleName = stringFor(module, QStringLiteral("bankLabel"));
            }
            if (moduleName.isEmpty()) {
                moduleName = stringFor(module, QStringLiteral("partNumber"));
            }
            const qint64 capacity = static_cast<qint64>(doubleFor(module, QStringLiteral("capacityBytes")));
            const int configuredSpeed = intFor(module, QStringLiteral("configuredSpeedMHz"));
            const int ratedSpeed = intFor(module, QStringLiteral("speedMHz"));
            QString timing = t(QStringLiteral("overview.memoryTimingUnavailable"));
            const QJsonValue timingValue = valueFor(module, QStringLiteral("timings"));
            if (timingValue.isObject()) {
                ++timingCount;
                const QJsonObject timings = timingValue.toObject();
                const int commandRate = intFor(timings, QStringLiteral("commandRate"));
                timing = QStringLiteral("CL%1-%2-%3-%4%5")
                             .arg(
                                 QString::number(intFor(timings, QStringLiteral("casLatency"))),
                                 QString::number(intFor(timings, QStringLiteral("trcd"))),
                                 QString::number(intFor(timings, QStringLiteral("trp"))),
                                 QString::number(intFor(timings, QStringLiteral("tras"))),
                                 commandRate > 0
                                     ? QStringLiteral(" / CR%1").arg(commandRate)
                                     : QString()
                             );
            }
            auto *line = new QLabel(
                QStringLiteral(
                    "%1 [%2]: %3 %4 GiB / %5 %6 MT/s / %7 %8 MT/s / %9 %10"
                )
                    .arg(
                        moduleName,
                        stringFor(module, QStringLiteral("memoryType")),
                        t(QStringLiteral("overview.memorySize")),
                        roundedGigabytes(capacity, 1),
                        t(QStringLiteral("overview.memoryConfiguredSpeed")),
                        configuredSpeed > 0 ? QString::number(configuredSpeed)
                                            : t(QStringLiteral("overview.hardwareUnavailable")),
                        t(QStringLiteral("overview.memoryRatedSpeed")),
                        ratedSpeed > 0 ? QString::number(ratedSpeed)
                                       : t(QStringLiteral("overview.hardwareUnavailable")),
                        t(QStringLiteral("overview.timing")),
                        timing
                    )
            );
            line->setWordWrap(true);
            line->setObjectName(QStringLiteral("bodyText"));
            m_hardwareLayout->addWidget(line);
        }

        if (memory.isEmpty()) {
            auto *fallback = new QLabel(
                QStringLiteral("%1 / %2")
                    .arg(
                        stringFor(hardware, QStringLiteral("memorySummary")),
                        stringFor(hardware, QStringLiteral("memoryTimingMessage"))
                    )
            );
            fallback->setWordWrap(true);
            fallback->setObjectName(QStringLiteral("mutedText"));
            m_hardwareLayout->addWidget(fallback);
        } else if (timingCount == 0) {
            auto *help = new QLabel(t(QStringLiteral("overview.memoryTimingHelp")));
            help->setWordWrap(true);
            help->setObjectName(QStringLiteral("mutedText"));
            m_hardwareLayout->addWidget(help);
        }

        const QString osCaption = stringFor(hardware, QStringLiteral("osCaption"));
        if (!osCaption.isEmpty() && osCaption != QStringLiteral("Unavailable")) {
            setMetric(
                QStringLiteral("os"),
                QStringLiteral("%1 %2")
                    .arg(osCaption, stringFor(hardware, QStringLiteral("osBuild")))
            );
        }
    }

    void buildRulesPage(int pageVersion)
    {
        setPageHeader(
            t(QStringLiteral("nav.rules")),
            t(QStringLiteral("rules.details"))
        );

        auto *filterRow = new QHBoxLayout;
        auto *filterLabel = new QLabel(QStringLiteral("%1:").arg(t(QStringLiteral("rules.category"))));
        m_ruleFilter = new QComboBox;
        m_ruleFilter->setMinimumWidth(180);
        m_ruleFilter->addItem(t(QStringLiteral("categories.all")), QString());
        for (const QString &category : {
                 QStringLiteral("power_cpu"),
                 QStringLiteral("latency_scheduler"),
                 QStringLiteral("network"),
                 QStringLiteral("graphics"),
                 QStringLiteral("input_response"),
                 QStringLiteral("startup_services"),
                 QStringLiteral("storage"),
                 QStringLiteral("hardware_binding"),
                 QStringLiteral("system_shell"),
             }) {
            m_ruleFilter->addItem(categoryName(category), category);
        }
        filterRow->addWidget(filterLabel);
        filterRow->addWidget(m_ruleFilter);
        filterRow->addStretch(1);
        auto *refresh = commandButton(
            t(QStringLiteral("app.refresh")),
            QStringLiteral("secondary"),
            QStringLiteral("refresh")
        );
        refresh->setMinimumWidth(90);
        filterRow->addWidget(refresh);
        m_pageLayout->addLayout(filterRow);

        auto *actionRow = new QHBoxLayout;
        auto *selectAll = commandButton(t(QStringLiteral("rules.selectAll")), QStringLiteral("secondary"));
        auto *clearSelection = commandButton(t(QStringLiteral("rules.clearSelection")), QStringLiteral("secondary"));
        auto *selectApplicable = commandButton(t(QStringLiteral("rules.selectApplicable")), QStringLiteral("secondary"));
        auto *batchPreflight = commandButton(t(QStringLiteral("rules.batchPreflight")), QStringLiteral("secondary"));
        auto *batchApply = commandButton(t(QStringLiteral("rules.batchApply")), QStringLiteral("warning"));
        actionRow->addWidget(selectAll);
        actionRow->addWidget(clearSelection);
        actionRow->addWidget(selectApplicable);
        actionRow->addStretch(1);
        actionRow->addWidget(batchPreflight);
        actionRow->addWidget(batchApply);
        m_pageLayout->addLayout(actionRow);

        auto *splitter = new QSplitter(Qt::Horizontal);
        splitter->setChildrenCollapsible(false);

        m_ruleTable = new QTableWidget;
        m_ruleTable->setObjectName(QStringLiteral("table"));
        m_ruleTable->setColumnCount(6);
        m_ruleTable->setHorizontalHeaderLabels({
            QString(),
            t(QStringLiteral("rules.name")),
            t(QStringLiteral("rules.applicability")),
            t(QStringLiteral("rules.risk")),
            t(QStringLiteral("rules.state")),
            t(QStringLiteral("rules.systemCheck")),
        });
        m_ruleTable->setSelectionBehavior(QAbstractItemView::SelectRows);
        m_ruleTable->setSelectionMode(QAbstractItemView::SingleSelection);
        m_ruleTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
        m_ruleTable->setShowGrid(false);
        m_ruleTable->setAlternatingRowColors(false);
        m_ruleTable->verticalHeader()->setVisible(false);
        m_ruleTable->verticalHeader()->setDefaultSectionSize(40);
        m_ruleTable->horizontalHeader()->setFixedHeight(38);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Fixed);
        m_ruleTable->horizontalHeader()->resizeSection(0, 34);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(4, QHeaderView::ResizeToContents);
        m_ruleTable->horizontalHeader()->setSectionResizeMode(5, QHeaderView::ResizeToContents);
        splitter->addWidget(m_ruleTable);

        auto *detailPanel = new QWidget;
        detailPanel->setObjectName(QStringLiteral("detailPanel"));
        auto *detailLayout = new QVBoxLayout(detailPanel);
        detailLayout->setContentsMargins(16, 12, 16, 14);
        detailLayout->setSpacing(10);
        auto *detailActions = new QHBoxLayout;
        detailActions->addStretch(1);
        auto *dryRun = commandButton(t(QStringLiteral("rules.dryRun")), QStringLiteral("secondary"));
        auto *apply = commandButton(t(QStringLiteral("rules.apply")), QStringLiteral("warning"));
        auto *restore = commandButton(t(QStringLiteral("rules.restore")), QStringLiteral("primary"));
        detailActions->addWidget(dryRun);
        detailActions->addWidget(apply);
        detailActions->addWidget(restore);
        detailLayout->addLayout(detailActions);
        m_ruleDetails = new QTextEdit;
        m_ruleDetails->setObjectName(QStringLiteral("ruleDetails"));
        m_ruleDetails->setReadOnly(true);
        m_ruleDetails->setText(t(QStringLiteral("rules.loading")));
        detailLayout->addWidget(m_ruleDetails, 1);
        splitter->addWidget(detailPanel);
        splitter->setStretchFactor(0, 3);
        splitter->setStretchFactor(1, 2);
        splitter->setSizes({760, 500});
        m_pageLayout->addWidget(splitter, 1);

        connect(m_ruleFilter, &QComboBox::currentIndexChanged, this, [this] {
            populateRuleTable();
        });
        connect(refresh, &QPushButton::clicked, this, [this, pageVersion] {
            m_auditRows = {};
            m_checkedRuleIds.clear();
            if (m_ruleTable != nullptr) {
                m_ruleTable->setRowCount(0);
            }
            if (m_ruleDetails != nullptr) {
                m_ruleDetails->setText(t(QStringLiteral("rules.loading")));
            }
            loadAudit(pageVersion);
        });
        connect(selectAll, &QPushButton::clicked, this, [this] {
            setVisibleSelection(QStringLiteral("all"));
        });
        connect(clearSelection, &QPushButton::clicked, this, [this] {
            setVisibleSelection(QStringLiteral("none"));
        });
        connect(selectApplicable, &QPushButton::clicked, this, [this] {
            setVisibleSelection(QStringLiteral("applicable"));
        });
        connect(batchPreflight, &QPushButton::clicked, this, [this] {
            runBatchPreflight();
        });
        connect(batchApply, &QPushButton::clicked, this, [this] {
            runBatchApply();
        });
        connect(m_ruleTable, &QTableWidget::currentCellChanged, this, [this](int row, int, int, int) {
            if (row < 0) {
                m_selectedRuleId.clear();
                return;
            }
            if (QTableWidgetItem *item = m_ruleTable->item(row, 0)) {
                m_selectedRuleId = item->data(Qt::UserRole).toString();
                updateRuleDetails();
            }
        });
        connect(m_ruleTable, &QTableWidget::itemChanged, this, [this](QTableWidgetItem *item) {
            if (m_populating || item == nullptr || item->column() != 0) {
                return;
            }
            const QString id = item->data(Qt::UserRole).toString();
            if (item->checkState() == Qt::Checked) {
                m_checkedRuleIds.insert(id);
            } else {
                m_checkedRuleIds.remove(id);
            }
        });

        if (m_auditRows.isEmpty()) {
            loadAudit(pageVersion);
        } else {
            populateRuleTable();
        }
    }

    void loadAudit(int pageVersion)
    {
        setStatus(t(QStringLiteral("rules.loading")));
        callAsync(
            QStringLiteral("Invoke-FelixAudit"),
            {},
            [this, pageVersion](const BridgeResponse &response) {
                if (!pageIsCurrent(pageVersion, QStringLiteral("rules"))) {
                    return;
                }
                if (!response.success) {
                    if (m_ruleDetails != nullptr) {
                        m_ruleDetails->setText(
                            QStringLiteral("%1%2")
                                .arg(t(QStringLiteral("rules.loadFailed")), response.error)
                        );
                    }
                    setStatus(response.error);
                    return;
                }
                m_auditRows = asArray(response.data);
                populateRuleTable();
                setStatus(t(QStringLiteral("app.statusReady")));
            },
            300000
        );
    }

    QJsonObject auditRow(const QString &ruleId) const
    {
        for (const QJsonValue &value : m_auditRows) {
            const QJsonObject row = value.toObject();
            if (stringFor(row, QStringLiteral("id")) == ruleId) {
                return row;
            }
        }
        return {};
    }

    bool ruleVisible(const QJsonObject &row) const
    {
        const QString category = m_ruleFilter == nullptr
            ? QString()
            : m_ruleFilter->currentData().toString();
        return category.isEmpty() || stringFor(row, QStringLiteral("category")) == category;
    }

    void populateRuleTable()
    {
        if (m_ruleTable == nullptr || m_auditRows.isEmpty()) {
            return;
        }
        m_populating = true;
        m_ruleTable->setRowCount(0);
        for (const QJsonValue &value : m_auditRows) {
            const QJsonObject row = value.toObject();
            if (!ruleVisible(row)) {
                continue;
            }
            const QString id = stringFor(row, QStringLiteral("id"));
            const int tableRow = m_ruleTable->rowCount();
            m_ruleTable->insertRow(tableRow);

            auto *check = new QTableWidgetItem;
            check->setFlags(Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsUserCheckable);
            check->setCheckState(m_checkedRuleIds.contains(id) ? Qt::Checked : Qt::Unchecked);
            check->setData(Qt::UserRole, id);
            check->setTextAlignment(Qt::AlignCenter);
            m_ruleTable->setItem(tableRow, 0, check);

            const QStringList cells{
                stringFor(row, QStringLiteral("name")),
                stringFor(row, QStringLiteral("applicabilityLabel")),
                riskText(stringFor(row, QStringLiteral("risk"))),
                statusText(stringFor(row, QStringLiteral("status"))),
                systemStateText(stringFor(row, QStringLiteral("systemState"))),
            };
            for (int column = 0; column < cells.size(); ++column) {
                auto *item = new QTableWidgetItem(cells.at(column));
                item->setData(Qt::UserRole, id);
                item->setToolTip(
                    column == 1
                        ? stringFor(row, QStringLiteral("applicabilityMessage"))
                        : (column == 4
                               ? stringFor(row, QStringLiteral("systemStateMessage"))
                               : cells.at(column))
                );
                if (column == 2) {
                    item->setForeground(
                        stringFor(row, QStringLiteral("risk")) == QStringLiteral("safe")
                            ? QColor(QStringLiteral("#18794e"))
                            : QColor(QStringLiteral("#b42318"))
                    );
                }
                m_ruleTable->setItem(tableRow, column + 1, item);
            }
        }
        m_populating = false;

        if (!m_selectedRuleId.isEmpty()) {
            for (int row = 0; row < m_ruleTable->rowCount(); ++row) {
                QTableWidgetItem *item = m_ruleTable->item(row, 0);
                if (item != nullptr && item->data(Qt::UserRole).toString() == m_selectedRuleId) {
                    m_ruleTable->selectRow(row);
                    break;
                }
            }
        } else if (m_ruleTable->rowCount() > 0) {
            m_ruleTable->selectRow(0);
        }
        updateRuleDetails();
    }

    void setVisibleSelection(const QString &mode)
    {
        if (m_ruleTable == nullptr) {
            return;
        }
        m_populating = true;
        for (int tableRow = 0; tableRow < m_ruleTable->rowCount(); ++tableRow) {
            QTableWidgetItem *check = m_ruleTable->item(tableRow, 0);
            if (check == nullptr) {
                continue;
            }
            const QString id = check->data(Qt::UserRole).toString();
            const QJsonObject row = auditRow(id);
            bool checked = false;
            if (mode == QStringLiteral("all")) {
                checked = true;
            } else if (mode == QStringLiteral("applicable")) {
                checked = boolFor(row, QStringLiteral("batchEligible"));
            }
            check->setCheckState(checked ? Qt::Checked : Qt::Unchecked);
            if (checked) {
                m_checkedRuleIds.insert(id);
            } else {
                m_checkedRuleIds.remove(id);
            }
        }
        m_populating = false;
        setStatus(
            mode == QStringLiteral("applicable")
                ? QStringLiteral("已选择 %1 项本机适用且可批量执行的规则。")
                      .arg(m_checkedRuleIds.size())
                : QStringLiteral("已选择 %1 项。").arg(m_checkedRuleIds.size())
        );
    }

    QStringList selectedRuleIds() const
    {
        QStringList ids;
        for (const QJsonValue &value : m_auditRows) {
            const QString id = stringFor(value.toObject(), QStringLiteral("id"));
            if (m_checkedRuleIds.contains(id)) {
                ids.append(id);
            }
        }
        return ids;
    }

    void updateRuleDetails()
    {
        if (m_ruleDetails == nullptr) {
            return;
        }
        if (m_selectedRuleId.isEmpty()) {
            m_ruleDetails->setText(t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        const QJsonObject rule = m_ruleById.value(m_selectedRuleId);
        if (rule.isEmpty()) {
            m_ruleDetails->setText(t(QStringLiteral("dialogs.selectRule")));
            return;
        }

        const QJsonObject row = auditRow(m_selectedRuleId);
        QStringList lines;
        lines.append(stringFor(rule, QStringLiteral("name")));
        lines.append(QString());
        lines.append(stringFor(rule, QStringLiteral("description")));
        lines.append(QString());
        lines.append(QStringLiteral("%1:").arg(t(QStringLiteral("rules.advice"))));
        lines.append(stringFor(rule, QStringLiteral("advice")));
        lines.append(QString());
        lines.append(QStringLiteral("%1:").arg(t(QStringLiteral("rules.consequences"))));
        for (const QJsonValue &value : arrayFor(rule, QStringLiteral("consequences"))) {
            lines.append(QStringLiteral("- %1").arg(scalarText(value)));
        }
        lines.append(QString());
        lines.append(
            QStringLiteral("%1: %2")
                .arg(
                    t(QStringLiteral("rules.category")),
                    categoryName(stringFor(rule, QStringLiteral("category")))
                )
        );
        lines.append(
            QStringLiteral("%1: %2")
                .arg(t(QStringLiteral("rules.risk")), riskText(stringFor(rule, QStringLiteral("risk"))))
        );
        lines.append(
            QStringLiteral("%1: %2")
                .arg(
                    t(QStringLiteral("rules.restart")),
                    boolFor(rule, QStringLiteral("requiresRestart"))
                        ? t(QStringLiteral("rules.yes"))
                        : t(QStringLiteral("rules.no"))
                )
        );
        lines.append(
            QStringLiteral("%1: %2 / %3")
                .arg(
                    t(QStringLiteral("rules.applicability")),
                    stringFor(row, QStringLiteral("applicabilityLabel")),
                    stringFor(row, QStringLiteral("applicabilityConfidence"))
                )
        );
        lines.append(stringFor(row, QStringLiteral("applicabilityMessage")));
        lines.append(
            QStringLiteral("%1: %2")
                .arg(
                    t(QStringLiteral("rules.systemCheck")),
                    systemStateText(stringFor(row, QStringLiteral("systemState")))
                )
        );
        lines.append(stringFor(row, QStringLiteral("systemStateMessage")));
        lines.append(QString());
        lines.append(QStringLiteral("%1:").arg(t(QStringLiteral("rules.benefits"))));
        for (const QJsonValue &value : arrayFor(rule, QStringLiteral("benefits"))) {
            lines.append(QStringLiteral("- %1").arg(scalarText(value)));
        }
        lines.append(QString());
        lines.append(QStringLiteral("%1:").arg(t(QStringLiteral("rules.drawbacks"))));
        for (const QJsonValue &value : arrayFor(rule, QStringLiteral("drawbacks"))) {
            lines.append(QStringLiteral("- %1").arg(scalarText(value)));
        }
        lines.append(QString());
        lines.append(QStringLiteral("%1:").arg(t(QStringLiteral("rules.compatibility"))));
        const QJsonObject compatibility = asObject(valueFor(rule, QStringLiteral("compatibility")));
        const QList<QPair<QString, QString>> compatibilityLabels{
            {QStringLiteral("scope"), t(QStringLiteral("rules.scope"))},
            {QStringLiteral("os"), t(QStringLiteral("rules.os"))},
            {QStringLiteral("cpuBrand"), t(QStringLiteral("rules.cpuBrand"))},
            {QStringLiteral("cpuSeries"), t(QStringLiteral("rules.cpuSeries"))},
            {QStringLiteral("gpuBrand"), t(QStringLiteral("rules.gpuBrand"))},
            {QStringLiteral("gpuDriver"), t(QStringLiteral("rules.gpuDriver"))},
            {QStringLiteral("memory"), t(QStringLiteral("rules.memory"))},
            {QStringLiteral("storage"), t(QStringLiteral("rules.storage"))},
            {QStringLiteral("device"), t(QStringLiteral("rules.device"))},
        };
        for (const auto &entry : compatibilityLabels) {
            if (compatibility.contains(entry.first)) {
                lines.append(
                    QStringLiteral("- %1: %2")
                        .arg(entry.second, stringFor(compatibility, entry.first))
                );
            }
        }

        const QJsonArray evidence = arrayFor(row, QStringLiteral("evidence"));
        lines.append(QString());
        lines.append(
            QStringLiteral("%1（%2）:")
                .arg(t(QStringLiteral("rules.evidence")), QString::number(evidence.size()))
        );
        for (const QJsonValue &value : evidence) {
            const QJsonObject item = value.toObject();
            lines.append(
                QStringLiteral("- [%1] %2 - %3")
                    .arg(
                        stringFor(item, QStringLiteral("kind")),
                        stringFor(item, QStringLiteral("title")),
                        stringFor(item, QStringLiteral("url"))
                    )
            );
        }
        m_ruleDetails->setPlainText(lines.join(QLatin1Char('\n')));
        m_ruleDetails->moveCursor(QTextCursor::Start);
    }

    bool promptRuleOptions(
        const QJsonObject &rule,
        QJsonObject *options,
        QString *error
    )
    {
        if (!boolFor(rule, QStringLiteral("requiresInput"))) {
            *options = {};
            return true;
        }
        QString mode = stringFor(rule, QStringLiteral("inputKind"));
        if (mode.isEmpty()) {
            mode = stringFor(rule, QStringLiteral("handler"));
        }

        QDialog dialog(this);
        dialog.setWindowTitle(stringFor(rule, QStringLiteral("name")));
        dialog.setMinimumWidth(540);
        auto *root = new QVBoxLayout(&dialog);
        auto *form = new QFormLayout;
        form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
        form->setLabelAlignment(Qt::AlignLeft);
        root->addLayout(form);

        QComboBox *adapterCombo = nullptr;
        QLineEdit *pathEdit = nullptr;
        QComboBox *priorityCombo = nullptr;
        QCheckBox *dhcpCheck = nullptr;
        QLineEdit *dnsServersEdit = nullptr;
        QComboBox *startupCombo = nullptr;
        QComboBox *serviceCombo = nullptr;
        QComboBox *startupTypeCombo = nullptr;
        QCheckBox *stopServiceCheck = nullptr;
        QComboBox *deviceCombo = nullptr;
        QLineEdit *maskEdit = nullptr;

        const auto addAdapterCombo = [this, form, &adapterCombo](const QString &label) {
            adapterCombo = new QComboBox;
            const BridgeResponse response = callBlocking(
                QStringLiteral("Get-FelixNetworkAdapterCandidates"),
                {},
                60000
            );
            if (response.success) {
                for (const QJsonValue &value : asArray(response.data)) {
                    const QJsonObject adapter = value.toObject();
                    const QString name = stringFor(adapter, QStringLiteral("Name"));
                    adapterCombo->addItem(name, adapter.toVariantMap());
                }
            }
            if (adapterCombo->count() == 0) {
                adapterCombo->addItem(t(QStringLiteral("overview.hardwareUnavailable")));
                adapterCombo->setEnabled(false);
            }
            form->addRow(label, adapterCombo);
        };
        const auto addBrowsePath = [this, form](QLineEdit *edit, const QString &label) {
            auto *row = new QWidget;
            auto *layout = new QHBoxLayout(row);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSpacing(6);
            auto *browse = commandButton(QStringLiteral("Browse..."));
            layout->addWidget(edit, 1);
            layout->addWidget(browse);
            connect(browse, &QPushButton::clicked, edit, [this, edit] {
                const QString path = QFileDialog::getOpenFileName(
                    this,
                    QStringLiteral("Applications (*.exe)"),
                    QFileInfo(edit->text()).absolutePath(),
                    QStringLiteral("Applications (*.exe)")
                );
                if (!path.isEmpty()) {
                    edit->setText(path);
                }
            });
            form->addRow(label, row);
        };

        if (mode == QStringLiteral("NetworkAdapter")) {
            addAdapterCombo(QStringLiteral("Adapter"));
        } else if (mode == QStringLiteral("ExecutablePath")) {
            pathEdit = new QLineEdit(QStringLiteral("C:\\Games\\game.exe"));
            addBrowsePath(pathEdit, QStringLiteral("Application EXE"));
        } else if (mode == QStringLiteral("ExecutablePriority")) {
            pathEdit = new QLineEdit(QStringLiteral("C:\\Games\\game.exe"));
            addBrowsePath(pathEdit, QStringLiteral("Application EXE"));
            priorityCombo = new QComboBox;
            priorityCombo->addItem(QStringLiteral("Above normal (recommended)"), 6);
            priorityCombo->addItem(QStringLiteral("Normal"), 2);
            form->addRow(QStringLiteral("CPU priority"), priorityCombo);
        } else if (mode == QStringLiteral("NicPower")) {
            addAdapterCombo(QStringLiteral("Adapter"));
        } else if (mode == QStringLiteral("DnsProfile")) {
            addAdapterCombo(QStringLiteral("Interface"));
            dhcpCheck = new QCheckBox(QStringLiteral("Use DHCP DNS"));
            form->addRow(QString(), dhcpCheck);
            dnsServersEdit = new QLineEdit(QStringLiteral("223.5.5.5,119.29.29.29"));
            form->addRow(QStringLiteral("DNS servers"), dnsServersEdit);
        } else if (mode == QStringLiteral("StartupItem")) {
            startupCombo = new QComboBox;
            const BridgeResponse response = callBlocking(
                QStringLiteral("Get-FelixStartupCandidates"),
                {},
                60000
            );
            if (response.success) {
                for (const QJsonValue &value : asArray(response.data)) {
                    const QJsonObject candidate = value.toObject();
                    startupCombo->addItem(
                        stringFor(candidate, QStringLiteral("name")),
                        candidate.toVariantMap()
                    );
                }
            }
            if (startupCombo->count() == 0) {
                startupCombo->addItem(t(QStringLiteral("overview.hardwareUnavailable")));
                startupCombo->setEnabled(false);
            }
            form->addRow(QStringLiteral("Startup item"), startupCombo);
        } else if (mode == QStringLiteral("ServiceState")) {
            serviceCombo = new QComboBox;
            const BridgeResponse response = callBlocking(
                QStringLiteral("Get-FelixServiceCandidates"),
                {},
                60000
            );
            if (response.success) {
                for (const QJsonValue &value : asArray(response.data)) {
                    const QJsonObject service = value.toObject();
                    QString label = stringFor(service, QStringLiteral("DisplayName"));
                    if (label.isEmpty()) {
                        label = stringFor(service, QStringLiteral("Name"));
                    }
                    serviceCombo->addItem(label, service.toVariantMap());
                }
            }
            if (serviceCombo->count() == 0) {
                serviceCombo->addItem(t(QStringLiteral("overview.hardwareUnavailable")));
                serviceCombo->setEnabled(false);
            }
            startupTypeCombo = new QComboBox;
            startupTypeCombo->addItems({
                QStringLiteral("Manual"),
                QStringLiteral("Disabled"),
                QStringLiteral("Automatic"),
            });
            stopServiceCheck = new QCheckBox(QStringLiteral("Stop the service now"));
            stopServiceCheck->setChecked(true);
            form->addRow(QStringLiteral("Service"), serviceCombo);
            form->addRow(QStringLiteral("Startup type"), startupTypeCombo);
            form->addRow(QString(), stopServiceCheck);
        } else if (mode == QStringLiteral("DeviceAffinity")) {
            deviceCombo = new QComboBox;
            const BridgeResponse response = callBlocking(
                QStringLiteral("Get-FelixInterruptCandidate"),
                {},
                60000
            );
            if (response.success) {
                for (const QJsonValue &value : asArray(response.data)) {
                    const QJsonObject candidate = value.toObject();
                    deviceCombo->addItem(
                        stringFor(candidate, QStringLiteral("name")),
                        candidate.toVariantMap()
                    );
                }
            }
            if (deviceCombo->count() == 0) {
                deviceCombo->addItem(t(QStringLiteral("overview.hardwareUnavailable")));
                deviceCombo->setEnabled(false);
            }
            maskEdit = new QLineEdit(QStringLiteral("0x1"));
            form->addRow(QStringLiteral("Device"), deviceCombo);
            form->addRow(QStringLiteral("CPU mask (hex, 0 resets)"), maskEdit);
        } else {
            *error = t(QStringLiteral("dialogs.inputRequired"));
            return false;
        }

        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
        buttons->button(QDialogButtonBox::Ok)->setText(QStringLiteral("OK"));
        buttons->button(QDialogButtonBox::Cancel)->setText(QStringLiteral("Cancel"));
        root->addWidget(buttons);
        connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
        connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

        if (dialog.exec() != QDialog::Accepted) {
            return false;
        }

        QJsonObject values;
        if (mode == QStringLiteral("NetworkAdapter")) {
            if (adapterCombo == nullptr || adapterCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            const QVariantMap adapter = adapterCombo->currentData().toMap();
            values.insert(QStringLiteral("AdapterName"), adapter.value(QStringLiteral("Name")).toString());
            values.insert(QStringLiteral("InterfaceAlias"), adapter.value(QStringLiteral("Name")).toString());
            values.insert(
                QStringLiteral("InterfaceGuid"),
                adapter.value(QStringLiteral("InterfaceGuid")).toString()
            );
        } else if (mode == QStringLiteral("ExecutablePath")) {
            if (pathEdit == nullptr || pathEdit->text().trimmed().isEmpty()) {
                return false;
            }
            values.insert(QStringLiteral("ExecutablePath"), pathEdit->text().trimmed());
        } else if (mode == QStringLiteral("ExecutablePriority")) {
            if (pathEdit == nullptr || pathEdit->text().trimmed().isEmpty() || priorityCombo == nullptr) {
                return false;
            }
            values.insert(QStringLiteral("ExecutablePath"), pathEdit->text().trimmed());
            values.insert(QStringLiteral("CpuPriorityClass"), priorityCombo->currentData().toInt());
        } else if (mode == QStringLiteral("NicPower")) {
            if (adapterCombo == nullptr || adapterCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            values.insert(
                QStringLiteral("AdapterName"),
                adapterCombo->currentData().toMap().value(QStringLiteral("Name")).toString()
            );
        } else if (mode == QStringLiteral("DnsProfile")) {
            if (adapterCombo == nullptr || adapterCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            QJsonArray servers;
            const QStringList serverList = dnsServersEdit->text().split(
                QRegularExpression(QStringLiteral("[,\\s]+")),
                Qt::SkipEmptyParts
            );
            for (const QString &server : serverList) {
                servers.append(server);
            }
            values.insert(
                QStringLiteral("InterfaceAlias"),
                adapterCombo->currentData().toMap().value(QStringLiteral("Name")).toString()
            );
            values.insert(QStringLiteral("Dhcp"), dhcpCheck != nullptr && dhcpCheck->isChecked());
            values.insert(QStringLiteral("DnsServers"), servers);
        } else if (mode == QStringLiteral("StartupItem")) {
            if (startupCombo == nullptr || startupCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            const QVariantMap item = startupCombo->currentData().toMap();
            if (item.value(QStringLiteral("enabled")).toBool()) {
                values.insert(
                    QStringLiteral("RegistryPath"),
                    item.value(QStringLiteral("registryPath")).toString()
                );
                values.insert(
                    QStringLiteral("ValueName"),
                    item.value(QStringLiteral("valueName")).toString()
                );
                values.insert(QStringLiteral("Enable"), false);
            } else {
                values.insert(
                    QStringLiteral("BackupPath"),
                    item.value(QStringLiteral("backupPath")).toString()
                );
                values.insert(QStringLiteral("Enable"), true);
            }
        } else if (mode == QStringLiteral("ServiceState")) {
            if (serviceCombo == nullptr || serviceCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            values.insert(
                QStringLiteral("ServiceName"),
                serviceCombo->currentData().toMap().value(QStringLiteral("Name")).toString()
            );
            values.insert(QStringLiteral("StartupType"), startupTypeCombo->currentText());
            values.insert(QStringLiteral("StopNow"), stopServiceCheck->isChecked());
        } else if (mode == QStringLiteral("DeviceAffinity")) {
            if (deviceCombo == nullptr || deviceCombo->currentData().toMap().isEmpty()) {
                *error = t(QStringLiteral("dialogs.unavailable"));
                return false;
            }
            const QVariantMap candidate = deviceCombo->currentData().toMap();
            values.insert(
                QStringLiteral("RegistryPath"),
                candidate.value(QStringLiteral("registryPath")).toString()
            );
            values.insert(
                QStringLiteral("InstanceId"),
                candidate.value(QStringLiteral("instanceId")).toString()
            );
            values.insert(QStringLiteral("CpuMask"), maskEdit->text().trimmed());
        }
        *options = values;
        return true;
    }

    void runDryRun()
    {
        if (m_selectedRuleId.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        const QJsonObject rule = m_ruleById.value(m_selectedRuleId);
        QJsonObject options;
        QString inputError;
        if (!promptRuleOptions(rule, &options, &inputError)) {
            if (!inputError.isEmpty()) {
                showInformation(QStringLiteral("稳优 StableTune"), inputError);
            }
            return;
        }
        const BridgeResponse response = callBlocking(
            QStringLiteral("Invoke-FelixDryRun"),
            QJsonObject{
                {QStringLiteral("ruleId"), m_selectedRuleId},
                {QStringLiteral("options"), options},
            }
        );
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            return;
        }
        const QJsonObject plan = asObject(response.data);
        showInformation(
            t(QStringLiteral("rules.dryRun")),
            jsonList(arrayFor(plan, QStringLiteral("plannedChanges")), QStringLiteral("\n"))
        );
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void runApply()
    {
        if (m_selectedRuleId.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        const QJsonObject rule = m_ruleById.value(m_selectedRuleId);
        const QJsonObject audit = auditRow(m_selectedRuleId);
        if (stringFor(audit, QStringLiteral("applicability")) == QStringLiteral("Conditional")) {
            if (!confirm(
                    t(QStringLiteral("rules.applicabilityConditional")),
                    t(QStringLiteral("dialogs.confirmConditional")),
                    QMessageBox::Warning
                )) {
                return;
            }
        }
        bool acceptRisk = false;
        if (stringFor(rule, QStringLiteral("risk")) == QStringLiteral("advanced")) {
            if (!confirm(
                    t(QStringLiteral("dialogs.acceptRiskTitle")),
                    t(QStringLiteral("dialogs.confirmAdvanced")),
                    QMessageBox::Warning
                )) {
                return;
            }
            acceptRisk = true;
        }

        const BridgeResponse policyResponse = callBlocking(QStringLiteral("Get-FelixRollbackPolicy"), {}, 60000);
        if (!policyResponse.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), policyResponse.error);
            return;
        }
        const QJsonObject policy = asObject(policyResponse.data);
        setStatus(
            boolFor(policy, QStringLiteral("requireSystemRestorePoint"))
                ? t(QStringLiteral("dialogs.dualRollbackChecking"))
                : t(QStringLiteral("dialogs.snapshotOnlyChecking"))
        );
        const BridgeResponse rollbackResponse = callBlocking(
            QStringLiteral("Test-FelixDualRollbackCapability"),
            QJsonObject{{QStringLiteral("ensureRestorePoint"), true}},
            600000
        );
        if (!rollbackResponse.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), rollbackResponse.error);
            return;
        }
        const QJsonObject rollback = asObject(rollbackResponse.data);
        if (!boolFor(rollback, QStringLiteral("available"))) {
            showError(
                t(QStringLiteral("dialogs.operationFailed")),
                QStringLiteral("%1\n%2: %3\n%4: %5")
                    .arg(
                        t(QStringLiteral("dialogs.rollbackUnavailable")),
                        t(QStringLiteral("overview.snapshot")),
                        stringFor(rollback, QStringLiteral("snapshotMessage")),
                        t(QStringLiteral("overview.systemRestorePoint")),
                        stringFor(rollback, QStringLiteral("restorePointMessage"))
                    )
            );
            return;
        }
        if (!boolFor(rollback, QStringLiteral("requiresSystemRestorePoint"))
            && !confirm(
                t(QStringLiteral("dialogs.snapshotOnlyTitle")),
                t(QStringLiteral("dialogs.snapshotOnlyConfirm")),
                QMessageBox::Warning
            )) {
            return;
        }

        QJsonObject options;
        QString inputError;
        if (!promptRuleOptions(rule, &options, &inputError)) {
            if (!inputError.isEmpty()) {
                showInformation(QStringLiteral("稳优 StableTune"), inputError);
            }
            return;
        }
        setStatus(t(QStringLiteral("rules.inProgress")));
        const BridgeResponse response = callBlocking(
            QStringLiteral("Invoke-FelixApply"),
            QJsonObject{
                {QStringLiteral("ruleId"), m_selectedRuleId},
                {QStringLiteral("options"), options},
                {QStringLiteral("acceptRisk"), acceptRisk},
            },
            3600000
        );
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            setStatus(t(QStringLiteral("dialogs.operationFailed")));
            return;
        }
        const QJsonObject result = asObject(response.data);
        showInformation(
            t(QStringLiteral("dialogs.operationComplete")),
            stringFor(result, QStringLiteral("crashGuard")) == QStringLiteral("AwaitingBoot")
                ? t(QStringLiteral("dialogs.restartGuard"))
                : t(QStringLiteral("dialogs.operationComplete"))
        );
        m_auditRows = {};
        showPage(QStringLiteral("rules"));
    }

    void runRestoreForSelectedRule()
    {
        if (m_selectedRuleId.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        const BridgeResponse response = callBlocking(
            QStringLiteral("Get-FelixHistory"),
            QJsonObject{{QStringLiteral("restorableOnly"), true}},
            60000
        );
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            return;
        }
        QString historyId;
        for (const QJsonValue &value : asArray(response.data)) {
            const QJsonObject record = value.toObject();
            if (stringFor(record, QStringLiteral("ruleId")) == m_selectedRuleId) {
                historyId = stringFor(record, QStringLiteral("historyId"));
                break;
            }
        }
        if (historyId.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("history.empty")));
            return;
        }
        const BridgeResponse restore = callBlocking(
            QStringLiteral("Invoke-FelixRestore"),
            QJsonObject{{QStringLiteral("historyId"), historyId}},
            600000
        );
        if (!restore.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), restore.error);
            return;
        }
        showInformation(
            t(QStringLiteral("dialogs.restoreComplete")),
            t(QStringLiteral("dialogs.restoreComplete"))
        );
        m_auditRows = {};
        showPage(QStringLiteral("rules"));
    }

    void runBatchPreflight()
    {
        const QStringList ids = selectedRuleIds();
        if (ids.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        QStringList lines;
        for (const QString &id : ids) {
            const QJsonObject row = auditRow(id);
            const QString name = stringFor(row, QStringLiteral("name"));
            if (!boolFor(row, QStringLiteral("batchEligible"))
                || boolFor(row, QStringLiteral("requiresInput"))) {
                lines.append(
                    QStringLiteral("%1: 跳过，%2")
                        .arg(name, stringFor(row, QStringLiteral("applicabilityMessage")))
                );
                continue;
            }
            const BridgeResponse response = callBlocking(
                QStringLiteral("Invoke-FelixDryRun"),
                QJsonObject{{QStringLiteral("ruleId"), id}},
                180000
            );
            if (!response.success) {
                lines.append(QStringLiteral("%1: 预检失败 - %2").arg(name, response.error));
                continue;
            }
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        name,
                        jsonList(
                            arrayFor(asObject(response.data), QStringLiteral("plannedChanges")),
                            QStringLiteral("；")
                        )
                    )
            );
        }
        showInformation(t(QStringLiteral("rules.batchPreflight")), lines.join(QLatin1Char('\n')));
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void runBatchApply()
    {
        const QStringList ids = selectedRuleIds();
        if (ids.isEmpty()) {
            showInformation(QStringLiteral("稳优 StableTune"), t(QStringLiteral("dialogs.selectRule")));
            return;
        }
        if (!confirm(
                t(QStringLiteral("rules.batchApply")),
                t(QStringLiteral("dialogs.confirmBatch")),
                QMessageBox::Question
            )) {
            return;
        }
        bool hasAdvanced = false;
        bool hasConditional = false;
        for (const QString &id : ids) {
            const QJsonObject row = auditRow(id);
            hasAdvanced = hasAdvanced || stringFor(row, QStringLiteral("risk")) != QStringLiteral("safe");
            hasConditional = hasConditional
                || stringFor(row, QStringLiteral("applicability")) == QStringLiteral("Conditional");
        }
        if (hasAdvanced
            && !confirm(
                t(QStringLiteral("dialogs.acceptRiskTitle")),
                t(QStringLiteral("dialogs.confirmAdvanced")),
                QMessageBox::Warning
            )) {
            return;
        }
        if (hasConditional
            && !confirm(
                t(QStringLiteral("rules.applicabilityConditional")),
                t(QStringLiteral("dialogs.confirmConditional")),
                QMessageBox::Warning
            )) {
            return;
        }

        const BridgeResponse rollbackResponse = callBlocking(
            QStringLiteral("Test-FelixDualRollbackCapability"),
            QJsonObject{{QStringLiteral("force"), true}},
            600000
        );
        if (!rollbackResponse.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), rollbackResponse.error);
            return;
        }
        const QJsonObject rollback = asObject(rollbackResponse.data);
        if (!boolFor(rollback, QStringLiteral("available"))) {
            showError(
                t(QStringLiteral("dialogs.operationFailed")),
                t(QStringLiteral("dialogs.rollbackUnavailable"))
            );
            return;
        }
        if (!boolFor(rollback, QStringLiteral("requiresSystemRestorePoint"))
            && !confirm(
                t(QStringLiteral("dialogs.snapshotOnlyTitle")),
                t(QStringLiteral("dialogs.snapshotOnlyConfirm")),
                QMessageBox::Warning
            )) {
            return;
        }

        QJsonArray ruleIds;
        for (const QString &id : ids) {
            ruleIds.append(id);
        }
        setStatus(t(QStringLiteral("rules.inProgress")));
        const BridgeResponse response = callBlocking(
            QStringLiteral("Invoke-FelixBatchApply"),
            QJsonObject{
                {QStringLiteral("ruleIds"), ruleIds},
                {QStringLiteral("acceptRisk"), true},
            },
            7200000
        );
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            setStatus(t(QStringLiteral("dialogs.operationFailed")));
            return;
        }
        const QJsonObject result = asObject(response.data);
        QString message = stringFor(result, QStringLiteral("message"));
        for (const QJsonValue &value : arrayFor(result, QStringLiteral("applied"))) {
            if (boolFor(value.toObject(), QStringLiteral("requiresRestart"))) {
                message += QLatin1Char('\n') + t(QStringLiteral("dialogs.restartGuard"));
                break;
            }
        }
        showInformation(t(QStringLiteral("dialogs.batchComplete")), message);
        m_auditRows = {};
        showPage(QStringLiteral("rules"));
    }

    void buildHistoryPage(int pageVersion)
    {
        Q_UNUSED(pageVersion)
        setPageHeader(t(QStringLiteral("nav.history")), {});
        const BridgeResponse response = callBlocking(QStringLiteral("Get-FelixHistory"), {}, 60000);
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            return;
        }
        const QJsonArray records = asArray(response.data);
        if (records.isEmpty()) {
            auto *empty = new QLabel(t(QStringLiteral("history.empty")));
            empty->setObjectName(QStringLiteral("mutedText"));
            m_pageLayout->addWidget(empty);
            m_pageLayout->addStretch(1);
            setStatus(t(QStringLiteral("app.statusReady")));
            return;
        }
        auto *table = createTable({
            t(QStringLiteral("history.operation")),
            t(QStringLiteral("history.rule")),
            t(QStringLiteral("history.time")),
            t(QStringLiteral("history.status")),
            t(QStringLiteral("history.restart")),
            t(QStringLiteral("history.restorePoint")),
            t(QStringLiteral("history.message")),
        });
        table->setRowCount(records.size());
        for (int row = 0; row < records.size(); ++row) {
            const QJsonObject record = records.at(row).toObject();
            const QStringList cells{
                stringFor(record, QStringLiteral("historyId")),
                stringFor(record, QStringLiteral("ruleName")),
                formatDateTime(stringFor(record, QStringLiteral("updatedAt"))),
                statusText(stringFor(record, QStringLiteral("status"))),
                boolFor(record, QStringLiteral("requiresRestart"))
                    ? t(QStringLiteral("rules.yes"))
                    : t(QStringLiteral("rules.no")),
                stringFor(record, QStringLiteral("restorePointId")),
                stringFor(record, QStringLiteral("message")),
            };
            setTableRow(table, row, cells);
        }
        finishTable(table, {230, 230, 150, 90, 70, 110, 360});
        m_pageLayout->addWidget(table, 1);
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void buildLogsPage(int pageVersion)
    {
        Q_UNUSED(pageVersion)
        setPageHeader(
            t(QStringLiteral("logs.title")),
            t(QStringLiteral("logs.description"))
        );
        auto *toolbar = new QHBoxLayout;
        auto *refresh = commandButton(
            t(QStringLiteral("logs.refresh")),
            QStringLiteral("secondary"),
            QStringLiteral("refresh")
        );
        auto *open = commandButton(
            t(QStringLiteral("logs.openDirectory")),
            QStringLiteral("secondary"),
            QStringLiteral("folder")
        );
        toolbar->addWidget(refresh);
        toolbar->addWidget(open);
        toolbar->addStretch(1);
        m_pageLayout->addLayout(toolbar);

        const BridgeResponse response = callBlocking(
            QStringLiteral("Get-FelixLog"),
            QJsonObject{{QStringLiteral("last"), 1000}},
            60000
        );
        if (!response.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
            return;
        }
        const QJsonArray records = asArray(response.data);
        if (records.isEmpty()) {
            auto *empty = new QLabel(t(QStringLiteral("logs.empty")));
            empty->setObjectName(QStringLiteral("mutedText"));
            m_pageLayout->addWidget(empty);
            m_pageLayout->addStretch(1);
        } else {
            auto *table = createTable({
                t(QStringLiteral("logs.time")),
                t(QStringLiteral("logs.level")),
                t(QStringLiteral("logs.event")),
                t(QStringLiteral("logs.rule")),
                t(QStringLiteral("logs.history")),
                t(QStringLiteral("logs.message")),
            });
            table->setRowCount(records.size());
            for (int row = 0; row < records.size(); ++row) {
                const QJsonObject record = records.at(row).toObject();
                setTableRow(table, row, {
                    formatDateTime(stringFor(record, QStringLiteral("timestamp"))),
                    stringFor(record, QStringLiteral("level")),
                    stringFor(record, QStringLiteral("event")),
                    stringFor(record, QStringLiteral("ruleId")),
                    stringFor(record, QStringLiteral("historyId")),
                    stringFor(record, QStringLiteral("message")),
                });
            }
            finishTable(table, {160, 80, 190, 180, 220, 460});
            m_pageLayout->addWidget(table, 1);
        }

        connect(refresh, &QPushButton::clicked, this, [this] {
            showPage(QStringLiteral("logs"));
        });
        connect(open, &QPushButton::clicked, this, [this] {
            const BridgeResponse statePath = callBlocking(
                QStringLiteral("Get-FelixStatePath"),
                QJsonObject{{QStringLiteral("childPath"), QStringLiteral("logs")}},
                30000
            );
            if (!statePath.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), statePath.error);
                return;
            }
            const QString path = scalarText(statePath.data);
            QDir().mkpath(path);
            QProcess::startDetached(QStringLiteral("explorer.exe"), {QDir::toNativeSeparators(path)});
        });
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void buildRestorePage(int pageVersion)
    {
        Q_UNUSED(pageVersion)
        setPageHeader(
            t(QStringLiteral("restore.title")),
            t(QStringLiteral("restore.description"))
        );
        auto *toolbar = new QHBoxLayout;
        auto *restoreSelected = commandButton(
            t(QStringLiteral("restore.restoreSelected")),
            QStringLiteral("primary")
        );
        auto *restoreAll = commandButton(t(QStringLiteral("restore.restoreAll")));
        auto *testRollback = commandButton(
            t(QStringLiteral("restore.testRollback")),
            QStringLiteral("secondary")
        );
        auto *openSystemRestore = commandButton(
            t(QStringLiteral("restore.openSystemRestore")),
            QStringLiteral("secondary")
        );
        toolbar->addWidget(restoreSelected);
        toolbar->addWidget(restoreAll);
        toolbar->addWidget(testRollback);
        toolbar->addWidget(openSystemRestore);
        toolbar->addStretch(1);
        m_pageLayout->addLayout(toolbar);

        const BridgeResponse rollbackResponse = callBlocking(
            QStringLiteral("Test-FelixDualRollbackCapability"),
            {},
            300000
        );
        const QJsonObject rollback = asObject(rollbackResponse.data);
        auto *rollbackText = new QLabel;
        rollbackText->setWordWrap(true);
        rollbackText->setObjectName(QStringLiteral("noticeText"));
        if (!rollbackResponse.success) {
            rollbackText->setText(rollbackResponse.error);
            rollbackText->setProperty("state", QStringLiteral("bad"));
        } else {
            QStringList lines;
            const bool independent = stringFor(rollback, QStringLiteral("mode"))
                == QStringLiteral("IndependentSnapshot");
            const bool available = boolFor(rollback, QStringLiteral("available"));
            lines.append(
                independent
                    ? (available ? t(QStringLiteral("dialogs.snapshotOnlyReady"))
                                 : t(QStringLiteral("dialogs.rollbackUnavailable")))
                    : (available ? t(QStringLiteral("dialogs.rollbackReady"))
                                 : t(QStringLiteral("dialogs.rollbackUnavailable")))
            );
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("restore.snapshotMode")),
                        boolFor(rollback, QStringLiteral("snapshotAvailable"))
                            ? t(QStringLiteral("restore.snapshotReady"))
                            : t(QStringLiteral("restore.snapshotUnavailable"))
                    )
            );
            lines.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("restore.systemPoint")),
                        independent
                            ? t(QStringLiteral("restore.pointNotRequired"))
                            : (boolFor(rollback, QStringLiteral("restorePointAvailable"))
                                   ? t(QStringLiteral("restore.pointAvailable"))
                                   : t(QStringLiteral("restore.pointUnavailable")))
                    )
            );
            lines.append(stringFor(rollback, QStringLiteral("message")));
            if (independent) {
                lines.append(t(QStringLiteral("restore.snapshotOnlyDescription")));
            }
            rollbackText->setText(lines.join(QLatin1Char('\n')));
            rollbackText->setProperty("state", available ? QStringLiteral("good") : QStringLiteral("bad"));
        }
        m_pageLayout->addWidget(rollbackText);

        const BridgeResponse historyResponse = callBlocking(
            QStringLiteral("Get-FelixHistory"),
            QJsonObject{{QStringLiteral("restorableOnly"), true}},
            60000
        );
        if (!historyResponse.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), historyResponse.error);
            return;
        }
        const QJsonArray records = asArray(historyResponse.data);
        m_restoreTable = createTable({
            t(QStringLiteral("history.rule")),
            t(QStringLiteral("history.time")),
            t(QStringLiteral("history.status")),
            t(QStringLiteral("history.restorePoint")),
            t(QStringLiteral("history.message")),
        });
        m_restoreTable->setRowCount(records.size());
        for (int row = 0; row < records.size(); ++row) {
            const QJsonObject record = records.at(row).toObject();
            setTableRow(m_restoreTable, row, {
                stringFor(record, QStringLiteral("ruleName")),
                formatDateTime(stringFor(record, QStringLiteral("updatedAt"))),
                statusText(stringFor(record, QStringLiteral("status"))),
                stringFor(record, QStringLiteral("restorePointId")),
                stringFor(record, QStringLiteral("message")),
            });
            m_restoreTable->item(row, 0)->setData(
                Qt::UserRole,
                stringFor(record, QStringLiteral("historyId"))
            );
        }
        finishTable(m_restoreTable, {260, 160, 100, 110, 420});
        m_pageLayout->addWidget(m_restoreTable, 1);

        connect(restoreSelected, &QPushButton::clicked, this, [this] {
            const int row = m_restoreTable == nullptr ? -1 : m_restoreTable->currentRow();
            if (row < 0 || m_restoreTable->item(row, 0) == nullptr) {
                showInformation(
                    QStringLiteral("稳优 StableTune"),
                    t(QStringLiteral("dialogs.selectHistory"))
                );
                return;
            }
            const QString historyId = m_restoreTable->item(row, 0)->data(Qt::UserRole).toString();
            const BridgeResponse response = callBlocking(
                QStringLiteral("Invoke-FelixRestore"),
                QJsonObject{{QStringLiteral("historyId"), historyId}},
                600000
            );
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            showInformation(
                t(QStringLiteral("dialogs.restoreComplete")),
                t(QStringLiteral("dialogs.restoreComplete"))
            );
            m_auditRows = {};
            showPage(QStringLiteral("restore"));
        });
        connect(restoreAll, &QPushButton::clicked, this, [this] {
            if (!confirm(
                    t(QStringLiteral("restore.title")),
                    t(QStringLiteral("dialogs.confirmRestoreAll")),
                    QMessageBox::Question
                )) {
                return;
            }
            const BridgeResponse response = callBlocking(
                QStringLiteral("Invoke-FelixRestoreAll"),
                {},
                1800000
            );
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            int failed = 0;
            for (const QJsonValue &value : asArray(response.data)) {
                if (!boolFor(value.toObject(), QStringLiteral("success"))) {
                    ++failed;
                }
            }
            showInformation(
                t(QStringLiteral("dialogs.restoreComplete")),
                QStringLiteral("%1 %2 failed.").arg(t(QStringLiteral("dialogs.restoreComplete"))).arg(failed)
            );
            m_auditRows = {};
            showPage(QStringLiteral("restore"));
        });
        connect(testRollback, &QPushButton::clicked, this, [this] {
            const BridgeResponse response = callBlocking(
                QStringLiteral("Test-FelixDualRollbackCapability"),
                QJsonObject{{QStringLiteral("ensureRestorePoint"), true}},
                600000
            );
            if (!response.success) {
                showError(t(QStringLiteral("nav.restore")), response.error);
                return;
            }
            const QJsonObject result = asObject(response.data);
            const bool independent = stringFor(result, QStringLiteral("mode"))
                == QStringLiteral("IndependentSnapshot");
            const bool available = boolFor(result, QStringLiteral("available"));
            QStringList message;
            message.append(
                independent
                    ? (available ? t(QStringLiteral("dialogs.snapshotOnlyReady"))
                                 : t(QStringLiteral("dialogs.rollbackUnavailable")))
                    : (available ? t(QStringLiteral("dialogs.rollbackReady"))
                                 : t(QStringLiteral("dialogs.rollbackUnavailable")))
            );
            message.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("overview.snapshot")),
                        boolFor(result, QStringLiteral("snapshotAvailable"))
                            ? t(QStringLiteral("restore.snapshotReady"))
                            : t(QStringLiteral("restore.snapshotUnavailable"))
                    )
            );
            message.append(
                QStringLiteral("%1: %2")
                    .arg(
                        t(QStringLiteral("overview.systemRestorePoint")),
                        independent
                            ? t(QStringLiteral("restore.pointNotRequired"))
                            : (boolFor(result, QStringLiteral("restorePointAvailable"))
                                   ? t(QStringLiteral("restore.pointAvailable"))
                                   : t(QStringLiteral("restore.pointUnavailable")))
                    )
            );
            message.append(stringFor(result, QStringLiteral("snapshotMessage")));
            message.append(stringFor(result, QStringLiteral("restorePointMessage")));
            if (available) {
                showInformation(t(QStringLiteral("nav.restore")), message.join(QLatin1Char('\n')));
            } else {
                showError(t(QStringLiteral("nav.restore")), message.join(QLatin1Char('\n')));
            }
        });
        connect(openSystemRestore, &QPushButton::clicked, this, [] {
            QProcess::startDetached(QStringLiteral("rstrui.exe"), {});
        });
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void buildSettingsPage(int pageVersion)
    {
        Q_UNUSED(pageVersion)
        setPageHeader(t(QStringLiteral("nav.settings")), {});
        const BridgeResponse pathResponse = callBlocking(
            QStringLiteral("Get-FelixStatePath"),
            {},
            30000
        );
        const QString statePath = pathResponse.success
            ? scalarText(pathResponse.data)
            : m_bridge.stateRoot();
        auto *path = new QLabel(
            QStringLiteral("%1: %2").arg(t(QStringLiteral("settings.statePath")), statePath)
        );
        path->setWordWrap(true);
        path->setObjectName(QStringLiteral("bodyText"));
        m_pageLayout->addWidget(path);

        const BridgeResponse policyResponse = callBlocking(
            QStringLiteral("Get-FelixRollbackPolicy"),
            {},
            60000
        );
        if (!policyResponse.success) {
            showError(t(QStringLiteral("dialogs.operationFailed")), policyResponse.error);
            return;
        }
        const QJsonObject policy = asObject(policyResponse.data);
        auto *policyBox = new QGroupBox(t(QStringLiteral("settings.rollbackPolicy")));
        policyBox->setTitle(t(QStringLiteral("settings.rollbackPolicy")));
        auto *policyLayout = new QVBoxLayout(policyBox);
        auto *policyCheck = new QCheckBox(t(QStringLiteral("settings.dualRollback")));
        policyCheck->setChecked(boolFor(policy, QStringLiteral("requireSystemRestorePoint")));
        auto *policyDescription = new QLabel(t(QStringLiteral("settings.dualRollbackDescription")));
        policyDescription->setWordWrap(true);
        policyDescription->setObjectName(QStringLiteral("mutedText"));
        auto *policyStatus = new QLabel;
        policyStatus->setObjectName(QStringLiteral("policyStatus"));
        policyLayout->addWidget(policyCheck);
        policyLayout->addWidget(policyDescription);
        policyLayout->addWidget(policyStatus);
        m_pageLayout->addWidget(policyBox);

        const auto updatePolicyStatus = [this, policyStatus](bool enabled) {
            policyStatus->setText(
                enabled ? t(QStringLiteral("settings.dualRollbackEnabled"))
                        : t(QStringLiteral("settings.snapshotOnlyEnabled"))
            );
            policyStatus->setProperty(
                "state",
                enabled ? QStringLiteral("good") : QStringLiteral("warning")
            );
            policyStatus->style()->unpolish(policyStatus);
            policyStatus->style()->polish(policyStatus);
        };
        updatePolicyStatus(boolFor(policy, QStringLiteral("requireSystemRestorePoint")));

        connect(policyCheck, &QCheckBox::toggled, this, [this, policyCheck, updatePolicyStatus](bool enabled) {
            if (m_updatingPolicy) {
                return;
            }
            if (!enabled
                && !confirm(
                    t(QStringLiteral("settings.rollbackPolicy")),
                    t(QStringLiteral("settings.snapshotOnlyConfirm")),
                    QMessageBox::Warning
                )) {
                m_updatingPolicy = true;
                policyCheck->setChecked(true);
                m_updatingPolicy = false;
                return;
            }
            const BridgeResponse response = callBlocking(
                QStringLiteral("Set-FelixRollbackPolicy"),
                QJsonObject{{QStringLiteral("requireSystemRestorePoint"), enabled}},
                60000
            );
            if (!response.success) {
                m_updatingPolicy = true;
                policyCheck->setChecked(!enabled);
                m_updatingPolicy = false;
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            updatePolicyStatus(boolFor(asObject(response.data), QStringLiteral("requireSystemRestorePoint")));
            showInformation(
                t(QStringLiteral("settings.rollbackPolicy")),
                t(QStringLiteral("settings.rollbackPolicySaved"))
            );
        });

        auto *buttons = new QHBoxLayout;
        auto *open = commandButton(
            t(QStringLiteral("settings.openState")),
            QStringLiteral("secondary"),
            QStringLiteral("folder")
        );
        auto *clearHistory = commandButton(
            t(QStringLiteral("settings.clearHistory")),
            QStringLiteral("secondary")
        );
        auto *purge = commandButton(
            t(QStringLiteral("settings.purgeQuarantine")),
            QStringLiteral("danger")
        );
        buttons->addWidget(open);
        buttons->addWidget(clearHistory);
        buttons->addWidget(purge);
        buttons->addStretch(1);
        m_pageLayout->addLayout(buttons);
        auto *danger = new QLabel(t(QStringLiteral("settings.dangerous")));
        danger->setObjectName(QStringLiteral("dangerText"));
        danger->setWordWrap(true);
        m_pageLayout->addWidget(danger);
        m_pageLayout->addStretch(1);

        connect(open, &QPushButton::clicked, this, [this] {
            const BridgeResponse response = callBlocking(QStringLiteral("Get-FelixStatePath"), {}, 30000);
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            const QString folder = scalarText(response.data);
            QDir().mkpath(folder);
            QProcess::startDetached(QStringLiteral("explorer.exe"), {QDir::toNativeSeparators(folder)});
        });
        connect(clearHistory, &QPushButton::clicked, this, [this] {
            if (!confirm(
                    t(QStringLiteral("nav.settings")),
                    t(QStringLiteral("settings.clearHistory")),
                    QMessageBox::Warning
                )) {
                return;
            }
            const BridgeResponse response = callBlocking(
                QStringLiteral("Clear-FelixHistoryIndex"),
                {},
                60000
            );
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            m_auditRows = {};
            showInformation(
                t(QStringLiteral("nav.settings")),
                t(QStringLiteral("dialogs.historyCleared"))
            );
        });
        connect(purge, &QPushButton::clicked, this, [this] {
            if (!confirm(
                    t(QStringLiteral("nav.settings")),
                    t(QStringLiteral("dialogs.confirmPurge")),
                    QMessageBox::Warning
                )) {
                return;
            }
            const BridgeResponse response = callBlocking(
                QStringLiteral("Clear-FelixQuarantine"),
                {},
                120000
            );
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            showInformation(
                t(QStringLiteral("nav.settings")),
                t(QStringLiteral("dialogs.quarantineCleared"))
            );
        });
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    void addAboutSection(const QString &title, const QString &body)
    {
        auto *heading = new QLabel(title);
        heading->setObjectName(QStringLiteral("sectionTitle"));
        m_pageLayout->addWidget(heading);
        auto *text = new QLabel(body);
        text->setTextInteractionFlags(Qt::TextSelectableByMouse);
        text->setWordWrap(true);
        text->setObjectName(QStringLiteral("bodyText"));
        m_pageLayout->addWidget(text);
        m_pageLayout->addSpacing(8);
    }

    void buildAboutPage(int pageVersion)
    {
        Q_UNUSED(pageVersion)
        setPageHeader(
            t(QStringLiteral("about.title")),
            t(QStringLiteral("about.description"))
        );
        const BridgeResponse statusResponse = callBlocking(
            QStringLiteral("Get-FelixSystemStatus"),
            {},
            180000
        );
        const QJsonObject status = asObject(statusResponse.data);
        const QString version = statusResponse.success
            ? stringFor(status, QStringLiteral("appVersion"))
            : QString();
        addAboutSection(
            t(QStringLiteral("about.project")),
            QStringLiteral(
                "%1: %2\n%3: https://github.com/HeFanweiming"
            )
                .arg(
                    t(QStringLiteral("about.version")),
                    version,
                    t(QStringLiteral("about.repository"))
                )
        );

        auto *links = new QHBoxLayout;
        auto *repository = commandButton(
            t(QStringLiteral("about.openRepository")),
            QStringLiteral("primary")
        );
        auto *state = commandButton(
            t(QStringLiteral("about.stateDirectory")),
            QStringLiteral("secondary"),
            QStringLiteral("folder")
        );
        links->addWidget(repository);
        links->addWidget(state);
        links->addStretch(1);
        m_pageLayout->addLayout(links);
        m_pageLayout->addSpacing(8);

        const BridgeResponse catalogResponse = callBlocking(
            QStringLiteral("Get-FelixApplicabilityCatalog"),
            {},
            60000
        );
        const QString reviewedAt = catalogResponse.success
            ? stringFor(asObject(catalogResponse.data), QStringLiteral("reviewedAt"))
            : QString();
        addAboutSection(
            t(QStringLiteral("about.research")),
            QStringLiteral("%1\n%2: %3")
                .arg(
                    t(QStringLiteral("about.researchDescription")),
                    t(QStringLiteral("about.reviewedAt")),
                    reviewedAt
                )
        );
        addAboutSection(
            t(QStringLiteral("about.safety")),
            t(QStringLiteral("about.safetyDescription"))
        );

        const BridgeResponse hardwareResponse = callBlocking(
            QStringLiteral("Get-FelixHardwareInventory"),
            {},
            180000
        );
        QString securityBody = t(QStringLiteral("about.securityStatusPending"));
        if (hardwareResponse.success) {
            const QJsonObject hardware = asObject(hardwareResponse.data);
            const QJsonValue securityValue = valueFor(hardware, QStringLiteral("deviceSecurity"));
            const QString security = securityValue.isObject()
                ? stringFor(securityValue.toObject(), QStringLiteral("message"))
                : t(QStringLiteral("overview.deviceSecurityUnavailable"));
            securityBody = QStringLiteral("%1: %2\n%3: %4")
                               .arg(
                                   t(QStringLiteral("overview.deviceSecurity")),
                                   security,
                                   t(QStringLiteral("overview.acePresence")),
                                   boolFor(hardware, QStringLiteral("antiCheatExpertInstalled"))
                                       ? t(QStringLiteral("overview.aceDetected"))
                                       : t(QStringLiteral("overview.aceNotDetected"))
                               );
        }
        addAboutSection(t(QStringLiteral("about.securityStatus")), securityBody);
        addAboutSection(
            t(QStringLiteral("about.crashGuard")),
            t(QStringLiteral("about.crashGuardDescription"))
        );
        m_pageLayout->addStretch(1);

        connect(repository, &QPushButton::clicked, this, [] {
            QDesktopServices::openUrl(
                QUrl(QStringLiteral("https://github.com/HeFanweiming"))
            );
        });
        connect(state, &QPushButton::clicked, this, [this] {
            const BridgeResponse response = callBlocking(QStringLiteral("Get-FelixStatePath"), {}, 30000);
            if (!response.success) {
                showError(t(QStringLiteral("dialogs.operationFailed")), response.error);
                return;
            }
            const QString folder = scalarText(response.data);
            QDir().mkpath(folder);
            QDesktopServices::openUrl(QUrl::fromLocalFile(folder));
        });
        setStatus(t(QStringLiteral("app.statusReady")));
    }

    QTableWidget *createTable(const QStringList &headers)
    {
        auto *table = new QTableWidget;
        table->setObjectName(QStringLiteral("table"));
        table->setColumnCount(headers.size());
        table->setHorizontalHeaderLabels(headers);
        table->setSelectionBehavior(QAbstractItemView::SelectRows);
        table->setSelectionMode(QAbstractItemView::SingleSelection);
        table->setEditTriggers(QAbstractItemView::NoEditTriggers);
        table->setShowGrid(false);
        table->setAlternatingRowColors(false);
        table->verticalHeader()->setVisible(false);
        table->verticalHeader()->setDefaultSectionSize(36);
        table->horizontalHeader()->setFixedHeight(38);
        return table;
    }

    void setTableRow(QTableWidget *table, int row, const QStringList &values)
    {
        for (int column = 0; column < values.size(); ++column) {
            auto *item = new QTableWidgetItem(values.at(column));
            item->setToolTip(values.at(column));
            table->setItem(row, column, item);
        }
    }

    void finishTable(QTableWidget *table, const QList<int> &widths)
    {
        for (int column = 0; column < widths.size() && column < table->columnCount(); ++column) {
            table->setColumnWidth(column, widths.at(column));
            table->horizontalHeader()->setSectionResizeMode(
                column,
                column == widths.size() - 1 ? QHeaderView::Stretch : QHeaderView::Interactive
            );
        }
    }

    void scheduleScreenshot()
    {
        QTimer::singleShot(300, this, [this] {
            if (m_pendingCalls > 0) {
                scheduleScreenshot();
                return;
            }
            if (grab().save(m_screenshotPath)) {
                setStatus(QStringLiteral("Screenshot saved: %1").arg(m_screenshotPath));
            }
            QTimer::singleShot(100, qApp, &QCoreApplication::quit);
        });
    }

    QString styleSheetText() const
    {
        return QStringLiteral(R"(
            * {
                font-family: "Microsoft YaHei UI", "Segoe UI";
                font-size: 13px;
                color: #1f2937;
            }
            QWidget#root, QWidget#main, QWidget#pageHost {
                background: #f6f7f9;
            }
            QFrame#sidebar {
                background: #edf0f2;
                border-right: 1px solid #d8dde2;
            }
            QLabel#brandMark {
                background: #2563eb;
                color: white;
                border-radius: 8px;
                font-size: 18px;
                font-weight: 700;
            }
            QLabel#brandTitle {
                color: #111827;
                font-size: 17px;
                font-weight: 700;
                margin-top: 8px;
            }
            QLabel#brandSubtitle {
                color: #667085;
                font-size: 11px;
            }
            QPushButton#navButton {
                background: transparent;
                border: none;
                border-radius: 6px;
                color: #475467;
                padding: 0 12px;
                text-align: left;
                font-weight: 600;
            }
            QPushButton#navButton:hover {
                background: #e1e5e9;
                color: #101828;
            }
            QPushButton#navButton:checked {
                background: #dbe7ff;
                color: #1d4ed8;
                border-left: 3px solid #2563eb;
                padding-left: 9px;
            }
            QLabel#backendBadge {
                background: #e4e7ea;
                border: 1px solid #d1d6db;
                border-radius: 8px;
                color: #475467;
                padding: 11px;
            }
            QLabel#pageTitle {
                font-size: 24px;
                font-weight: 700;
                color: #101828;
            }
            QLabel#pageSubtitle {
                color: #667085;
                font-size: 12px;
                margin-top: 3px;
            }
            QScrollArea#pageScroll {
                background: transparent;
            }
            QScrollArea#pageScroll > QWidget > QWidget {
                background: transparent;
            }
            QLabel#metricLabel {
                color: #667085;
                font-size: 11px;
            }
            QLabel#metricValue {
                color: #101828;
                font-size: 18px;
                font-weight: 650;
            }
            QLabel#sectionTitle {
                color: #101828;
                font-size: 16px;
                font-weight: 700;
                margin-top: 8px;
            }
            QLabel#subsectionTitle {
                color: #344054;
                font-size: 13px;
                font-weight: 700;
            }
            QLabel#bodyText, QLabel#noticeText {
                color: #344054;
                line-height: 1.45;
            }
            QLabel#mutedText {
                color: #667085;
            }
            QLabel#dangerText {
                color: #b42318;
            }
            QLabel[state="good"] {
                color: #18794e;
            }
            QLabel[state="bad"] {
                color: #b42318;
            }
            QLabel[state="warning"] {
                color: #b45309;
                font-weight: 650;
            }
            QFrame#separator {
                background: #e4e7ec;
                border: none;
            }
            QFrame#footer {
                background: #eef2f5;
                border: 1px solid #d8dee5;
                border-radius: 7px;
            }
            QLabel#statusText {
                color: #475467;
                font-size: 11px;
            }
            QPushButton {
                min-height: 32px;
                border-radius: 6px;
                padding: 0 13px;
                font-weight: 600;
            }
            QPushButton[variant="secondary"] {
                background: white;
                border: 1px solid #cbd2d9;
                color: #344054;
            }
            QPushButton[variant="secondary"]:hover {
                background: #f9fafb;
                border-color: #98a2b3;
            }
            QPushButton[variant="primary"] {
                background: #2563eb;
                border: 1px solid #1d4ed8;
                color: white;
            }
            QPushButton[variant="primary"]:hover {
                background: #1d4ed8;
            }
            QPushButton[variant="warning"] {
                background: #b45309;
                border: 1px solid #92400e;
                color: white;
            }
            QPushButton[variant="warning"]:hover {
                background: #92400e;
            }
            QPushButton[variant="danger"] {
                background: #b42318;
                border: 1px solid #912018;
                color: white;
            }
            QPushButton[variant="danger"]:hover {
                background: #912018;
            }
            QComboBox, QLineEdit {
                background: white;
                border: 1px solid #cbd2d9;
                border-radius: 6px;
                min-height: 30px;
                padding: 0 8px;
            }
            QComboBox:focus, QLineEdit:focus {
                border-color: #2563eb;
            }
            QCheckBox {
                spacing: 8px;
            }
            QTableWidget#table, QTextEdit#ruleDetails, QWidget#detailPanel, QGroupBox {
                background: white;
                border: 1px solid #d8dee5;
                border-radius: 7px;
            }
            QTableWidget#table {
                selection-background-color: #eaf1ff;
                selection-color: #101828;
                outline: 0;
            }
            QTableWidget#table::item {
                border-bottom: 1px solid #edf0f3;
                padding: 4px 6px;
            }
            QHeaderView::section {
                background: #f7f8fa;
                color: #667085;
                border: none;
                border-bottom: 1px solid #d8dee5;
                padding: 0 7px;
                font-size: 11px;
                font-weight: 700;
            }
            QTextEdit#ruleDetails {
                border: none;
                padding: 6px;
                selection-background-color: #dbe7ff;
            }
            QGroupBox {
                padding: 18px 12px 12px 12px;
                margin-top: 6px;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                left: 12px;
                padding: 0 4px;
                color: #101828;
                font-weight: 700;
            }
            QScrollBar:vertical {
                background: transparent;
                width: 10px;
                margin: 0;
            }
            QScrollBar::handle:vertical {
                background: #c7cdd4;
                border-radius: 5px;
                min-height: 28px;
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0;
            }
        )");
    }

    PowerShellBridge m_bridge;
    QString m_uiResourcePath;
    QString m_screenshotPath;
    QJsonObject m_text;
    QJsonArray m_ruleDefinitions;
    QHash<QString, QJsonObject> m_ruleById;
    QJsonArray m_auditRows;
    QSet<QString> m_checkedRuleIds;
    QHash<QString, QPushButton *> m_navButtons;
    QLabel *m_pageTitle = nullptr;
    QLabel *m_pageSubtitle = nullptr;
    QWidget *m_pageHost = nullptr;
    QVBoxLayout *m_pageLayout = nullptr;
    QLabel *m_status = nullptr;
    QGridLayout *m_overviewMetricsLayout = nullptr;
    QHash<QString, QLabel *> m_metricValues;
    QVBoxLayout *m_hardwareLayout = nullptr;
    QLabel *m_changeNotice = nullptr;
    QLabel *m_safetyNotice = nullptr;
    QComboBox *m_ruleFilter = nullptr;
    QTableWidget *m_ruleTable = nullptr;
    QTextEdit *m_ruleDetails = nullptr;
    QTableWidget *m_restoreTable = nullptr;
    QString m_currentPage;
    QString m_selectedRuleId;
    QString m_startupError;
    int m_pageVersion = 0;
    int m_pendingCalls = 0;
    bool m_populating = false;
    bool m_updatingPolicy = false;
    bool m_smokeTest = false;
};

QString findUiResource(const QString &repositoryRoot)
{
    const QString appDirectory = QCoreApplication::applicationDirPath();
    const QStringList candidates{
        QDir(appDirectory).filePath(
            QStringLiteral("powershell/StableTune/resources/ui.zh-CN.json")
        ),
        QDir(appDirectory).filePath(
            QStringLiteral("../powershell/StableTune/resources/ui.zh-CN.json")
        ),
        QDir(repositoryRoot).filePath(
            QStringLiteral("src/StableTune/resources/ui.zh-CN.json")
        ),
    };
    for (const QString &candidate : candidates) {
        if (QFileInfo::exists(candidate)) {
            return QFileInfo(candidate).absoluteFilePath();
        }
    }
    return {};
}

}  // namespace

int main(int argc, char *argv[])
{
    QApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("稳优 StableTune"));
    application.setOrganizationName(QStringLiteral("StableTune"));
    application.setStyle(QStringLiteral("Fusion"));

    const QString repositoryRoot = PowerShellBridge::defaultRepositoryRoot();
    const QString stateRoot = PowerShellBridge::defaultStateRoot();
    const QString uiResource = findUiResource(repositoryRoot);
    if (uiResource.isEmpty()) {
        QMessageBox::critical(
            nullptr,
            QStringLiteral("稳优 StableTune"),
            QStringLiteral("Unable to locate resources/ui.zh-CN.json.")
        );
        return 2;
    }

    const QStringList arguments = application.arguments();
    QString screenshotPath;
    const qsizetype screenshotIndex = arguments.indexOf(QStringLiteral("--screenshot"));
    if (screenshotIndex >= 0 && screenshotIndex + 1 < arguments.size()) {
        screenshotPath = arguments.at(screenshotIndex + 1);
    }
    const bool smokeTest = arguments.contains(QStringLiteral("--smoke-test"));
    QString initialPage = QStringLiteral("overview");
    const qsizetype pageIndex = arguments.indexOf(QStringLiteral("--page"));
    if (pageIndex >= 0 && pageIndex + 1 < arguments.size()) {
        initialPage = arguments.at(pageIndex + 1).trimmed().toLower();
    }

    MainWindow window(
        uiResource,
        repositoryRoot,
        stateRoot,
        screenshotPath,
        smokeTest,
        initialPage
    );
    if (!window.startupError().isEmpty()) {
        QMessageBox::critical(
            nullptr,
            QStringLiteral("稳优 StableTune"),
            window.startupError()
        );
        return 3;
    }
    window.show();

    if (smokeTest) {
        int exitCode = 0;
        QTimer::singleShot(300, &application, [&application, &window, &exitCode] {
            if (!window.runSmokeChecks()) {
                exitCode = 4;
            }
            application.exit(exitCode);
        });
    }
    return application.exec();
}
