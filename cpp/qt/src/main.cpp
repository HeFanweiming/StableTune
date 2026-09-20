#include "felix/core/rule_engine.h"
#include "felix/core/windows/network_adapters.h"
#include "felix/core/windows/system_facts.h"

#include <QAbstractTableModel>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QFrame>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMessageBox>
#include <QPixmap>
#include <QPushButton>
#include <QRegularExpression>
#include <QScrollArea>
#include <QSplitter>
#include <QStandardPaths>
#include <QTableView>
#include <QTimer>
#include <QUuid>
#include <QVBoxLayout>

#include <algorithm>

namespace {

using felix::core::IRuleHandler;
using felix::core::OperationContext;
using felix::core::OperationResult;
using felix::core::Requirement;
using felix::core::RuleDefinition;
using felix::core::RuleEngine;
using felix::core::RuleOptions;
using felix::core::RuleRisk;
using felix::core::windows::AdapterInfo;
using felix::core::windows::NetworkAdapters;
using felix::core::windows::SystemFacts;

QString riskLabel(RuleRisk risk)
{
    switch (risk) {
    case RuleRisk::Safe:
        return QStringLiteral("低风险");
    case RuleRisk::Advanced:
        return QStringLiteral("高级");
    case RuleRisk::Unknown:
        return QStringLiteral("未知");
    }
    return QStringLiteral("未知");
}

QString toneForRisk(RuleRisk risk)
{
    switch (risk) {
    case RuleRisk::Safe:
        return QStringLiteral("success");
    case RuleRisk::Advanced:
        return QStringLiteral("warning");
    case RuleRisk::Unknown:
        return QStringLiteral("neutral");
    }
    return QStringLiteral("neutral");
}

QString defaultCatalogPath()
{
    const QString environmentPath = qEnvironmentVariable("FELIX_RULE_CATALOG");
    const QStringList candidates{
        environmentPath,
        QDir(QCoreApplication::applicationDirPath())
            .filePath(QStringLiteral("rules/catalog.json")),
        QDir(QCoreApplication::applicationDirPath())
            .filePath(QStringLiteral("../rules/catalog.json")),
        QDir(QCoreApplication::applicationDirPath())
            .filePath(QStringLiteral("../share/StableTune/rules/catalog.json")),
    };
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo::exists(candidate)) {
            return QFileInfo(candidate).absoluteFilePath();
        }
    }
    return {};
}

QString defaultStateRoot()
{
    const QString override = qEnvironmentVariable("FELIX_OPTIMIZER_HOME");
    if (!override.isEmpty()) {
        return override;
    }
    return QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
}

bool promptRuleOptions(
    const RuleDefinition &rule,
    RuleOptions *options,
    QWidget *parent,
    QString *error
)
{
    QString mode = rule.raw.value(QStringLiteral("inputKind")).toString().trimmed();
    if (mode.isEmpty()) {
        mode = rule.handler;
    }

    QDialog dialog(parent);
    dialog.setWindowTitle(QStringLiteral("配置：%1").arg(rule.name));
    dialog.setMinimumWidth(520);
    auto *root = new QVBoxLayout(&dialog);
    auto *form = new QFormLayout;
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    root->addLayout(form);

    QHash<QString, QWidget *> fields;
    const auto addLine = [&](const QString &key,
                             const QString &label,
                             const QString &value = {},
                             const QString &placeholder = {}) {
        auto *edit = new QLineEdit(value);
        edit->setPlaceholderText(placeholder);
        fields.insert(key, edit);
        form->addRow(label, edit);
        return edit;
    };
    const auto addAdapterCombo = [&](const QString &label, bool includeGuid) {
        auto *combo = new QComboBox;
        QString adapterError;
        for (const AdapterInfo &adapter : NetworkAdapters::list(&adapterError)) {
            QVariantMap data{
                {QStringLiteral("AdapterName"), adapter.name},
                {QStringLiteral("InterfaceAlias"), adapter.name},
            };
            if (includeGuid) {
                data.insert(QStringLiteral("InterfaceGuid"), adapter.interfaceGuid);
            }
            combo->addItem(
                adapter.description.isEmpty()
                    ? adapter.name
                    : QStringLiteral("%1 · %2").arg(adapter.name, adapter.description),
                data
            );
        }
        if (combo->count() == 0) {
            combo->addItem(
                adapterError.isEmpty()
                    ? QStringLiteral("未检测到网络适配器")
                    : adapterError,
                QVariantMap{}
            );
            combo->setEnabled(false);
        }
        fields.insert(QStringLiteral("__adapter__"), combo);
        form->addRow(label, combo);
        return combo;
    };
    const auto addBrowseRow = [&](QLineEdit *edit) {
        auto *row = new QWidget;
        auto *layout = new QHBoxLayout(row);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(6);
        auto *browse = new QPushButton(QStringLiteral("浏览"));
        layout->addWidget(edit, 1);
        layout->addWidget(browse);
        QObject::connect(browse, &QPushButton::clicked, edit, [edit] {
            const QString path = QFileDialog::getOpenFileName(
                edit,
                QStringLiteral("选择程序"),
                QFileInfo(edit->text()).absolutePath(),
                QStringLiteral("Windows 程序 (*.exe)")
            );
            if (!path.isEmpty()) {
                edit->setText(QDir::toNativeSeparators(path));
            }
        });
        return row;
    };
    const auto addCombo = [&](const QString &key, const QString &label) {
        auto *combo = new QComboBox;
        fields.insert(key, combo);
        form->addRow(label, combo);
        return combo;
    };
    const auto addCheck = [&](const QString &key,
                              const QString &label,
                              bool checked = false) {
        auto *check = new QCheckBox(label);
        check->setChecked(checked);
        fields.insert(key, check);
        form->addRow(QString(), check);
        return check;
    };

    if (mode == QStringLiteral("NetworkAdapter")) {
        addAdapterCombo(QStringLiteral("网络适配器"), true);
    } else if (mode == QStringLiteral("ExecutablePath")) {
        QLineEdit *path = addLine(
            QStringLiteral("ExecutablePath"),
            QStringLiteral("程序 EXE"),
            {},
            QStringLiteral("C:\\Games\\game.exe")
        );
        form->removeRow(path);
        form->addRow(QStringLiteral("程序 EXE"), addBrowseRow(path));
    } else if (mode == QStringLiteral("ExecutablePriority")) {
        QLineEdit *path = addLine(
            QStringLiteral("ExecutablePath"),
            QStringLiteral("程序 EXE"),
            {},
            QStringLiteral("C:\\Games\\game.exe")
        );
        form->removeRow(path);
        form->addRow(QStringLiteral("程序 EXE"), addBrowseRow(path));
        QComboBox *priority = addCombo(
            QStringLiteral("CpuPriorityClass"),
            QStringLiteral("CPU 优先级")
        );
        priority->addItem(QStringLiteral("Above normal（推荐）"), 6);
        priority->addItem(QStringLiteral("Normal"), 2);
    } else if (mode == QStringLiteral("NicPower")) {
        addAdapterCombo(QStringLiteral("网络适配器"), false);
    } else if (mode == QStringLiteral("DnsProfile")) {
        addAdapterCombo(QStringLiteral("网络接口"), false);
        addCheck(QStringLiteral("Dhcp"), QStringLiteral("使用 DHCP 自动获取 DNS"));
        addLine(
            QStringLiteral("DnsServers"),
            QStringLiteral("DNS 服务器"),
            QStringLiteral("223.5.5.5,119.29.29.29"),
            QStringLiteral("多个地址使用逗号分隔")
        );
    } else if (mode == QStringLiteral("StartupItem")) {
        QComboBox *enabled = addCombo(QStringLiteral("Enable"), QStringLiteral("操作"));
        enabled->addItem(QStringLiteral("禁用启动项"), false);
        enabled->addItem(QStringLiteral("启用已停用项"), true);
        addLine(
            QStringLiteral("RegistryPath"),
            QStringLiteral("注册表路径"),
            {},
            QStringLiteral("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run")
        );
        addLine(QStringLiteral("ValueName"), QStringLiteral("值名称"));
        QComboBox *kind = addCombo(QStringLiteral("ValueKind"), QStringLiteral("值类型"));
        kind->addItems({
            QStringLiteral("String"),
            QStringLiteral("DWord"),
            QStringLiteral("QWord"),
            QStringLiteral("MultiString"),
        });
        addLine(QStringLiteral("Value"), QStringLiteral("值"));
        addLine(
            QStringLiteral("BackupPath"),
            QStringLiteral("备份项路径"),
            {},
            QStringLiteral("启用已停用项时填写")
        );
    } else if (mode == QStringLiteral("ServiceState")) {
        addLine(QStringLiteral("ServiceName"), QStringLiteral("服务名称"), QStringLiteral("SysMain"));
        QComboBox *startupType = addCombo(
            QStringLiteral("StartupType"),
            QStringLiteral("启动类型")
        );
        startupType->addItems({
            QStringLiteral("Manual"),
            QStringLiteral("Disabled"),
            QStringLiteral("Automatic"),
        });
        addCheck(QStringLiteral("StopNow"), QStringLiteral("立即停止服务"), true);
    } else if (mode == QStringLiteral("DeviceAffinity")) {
        addLine(
            QStringLiteral("InstanceId"),
            QStringLiteral("设备实例 ID"),
            {},
            QStringLiteral("PCI\\VEN_...")
        );
        addLine(
            QStringLiteral("RegistryPath"),
            QStringLiteral("注册表路径（可选）"),
            {},
            QStringLiteral("可直接指定 Affinity Policy 键")
        );
        addLine(
            QStringLiteral("CpuMask"),
            QStringLiteral("CPU 掩码"),
            QStringLiteral("0x1"),
            QStringLiteral("十六进制；0 表示清除")
        );
    } else {
        if (error != nullptr) {
            *error = QStringLiteral("暂不支持规则 '%1' 的输入类型 '%2'。")
                         .arg(rule.id, mode);
        }
        return false;
    }

    auto *buttons = new QDialogButtonBox(
        QDialogButtonBox::Ok | QDialogButtonBox::Cancel
    );
    buttons->button(QDialogButtonBox::Ok)->setText(QStringLiteral("确定"));
    buttons->button(QDialogButtonBox::Cancel)->setText(QStringLiteral("取消"));
    root->addWidget(buttons);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    if (dialog.exec() != QDialog::Accepted) {
        return false;
    }

    QVariantMap values;
    for (auto iterator = fields.cbegin(); iterator != fields.cend(); ++iterator) {
        const QString key = iterator.key();
        QWidget *field = iterator.value();
        if (key.startsWith(QStringLiteral("__"))) {
            continue;
        }
        if (auto *edit = qobject_cast<QLineEdit *>(field)) {
            if (key == QStringLiteral("DnsServers")) {
                values.insert(
                    key,
                    edit->text().split(
                        QRegularExpression(QStringLiteral("[,\\s]+")),
                        Qt::SkipEmptyParts
                    )
                );
            } else {
                values.insert(key, edit->text().trimmed());
            }
        } else if (auto *combo = qobject_cast<QComboBox *>(field)) {
            const QVariant data = combo->currentData();
            if (data.metaType().id() == QMetaType::QVariantMap) {
                const QVariantMap mapped = data.toMap();
                for (auto mappedIterator = mapped.cbegin();
                     mappedIterator != mapped.cend();
                     ++mappedIterator) {
                    values.insert(mappedIterator.key(), mappedIterator.value());
                }
            } else {
                values.insert(key, data);
            }
        } else if (auto *check = qobject_cast<QCheckBox *>(field)) {
            values.insert(key, check->isChecked());
        }
    }

    QWidget *adapterField = fields.value(QStringLiteral("__adapter__"));
    if (auto *adapterCombo = qobject_cast<QComboBox *>(adapterField)) {
        const QVariantMap adapterData = adapterCombo->currentData().toMap();
        if (adapterData.isEmpty()) {
            if (error != nullptr) {
                *error = QStringLiteral("请选择一个可用的网络适配器。");
            }
            return false;
        }
        for (auto iterator = adapterData.cbegin(); iterator != adapterData.cend(); ++iterator) {
            values.insert(iterator.key(), iterator.value());
        }
    }

    *options = RuleOptions(values);
    return true;
}

class RuleTableModel final : public QAbstractTableModel {
public:
    explicit RuleTableModel(QObject *parent = nullptr)
        : QAbstractTableModel(parent)
    {
    }

    void setRules(QList<RuleDefinition> rules)
    {
        beginResetModel();
        m_rules = std::move(rules);
        endResetModel();
    }

    int rowCount(const QModelIndex &parent = QModelIndex()) const override
    {
        return parent.isValid() ? 0 : m_rules.size();
    }

    int columnCount(const QModelIndex &parent = QModelIndex()) const override
    {
        return parent.isValid() ? 0 : 6;
    }

    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override
    {
        if (!index.isValid() || index.row() < 0 || index.row() >= m_rules.size()) {
            return {};
        }
        const RuleDefinition &rule = m_rules.at(index.row());
        if (role == Qt::DisplayRole) {
            switch (index.column()) {
            case 0:
                return rule.name;
            case 1:
                return rule.category;
            case 2:
                return riskLabel(rule.risk);
            case 3:
                return rule.requiresRestart ? QStringLiteral("需要") : QStringLiteral("否");
            case 4:
                return rule.requiresInput ? QStringLiteral("需要") : QStringLiteral("否");
            case 5:
                return rule.handler;
            default:
                return {};
            }
        }
        if (role == Qt::UserRole) {
            return rule.id;
        }
        if (role == Qt::TextAlignmentRole && index.column() >= 2) {
            return Qt::AlignCenter;
        }
        return {};
    }

    QVariant headerData(
        int section,
        Qt::Orientation orientation,
        int role = Qt::DisplayRole
    ) const override
    {
        if (orientation != Qt::Horizontal || role != Qt::DisplayRole) {
            return {};
        }
        switch (section) {
        case 0:
            return QStringLiteral("优化项");
        case 1:
            return QStringLiteral("分类");
        case 2:
            return QStringLiteral("风险");
        case 3:
            return QStringLiteral("重启");
        case 4:
            return QStringLiteral("输入");
        case 5:
            return QStringLiteral("处理器");
        default:
            return {};
        }
    }

    const RuleDefinition *ruleAt(const QModelIndex &index) const
    {
        if (!index.isValid() || index.row() < 0 || index.row() >= m_rules.size()) {
            return nullptr;
        }
        return &m_rules.at(index.row());
    }

private:
    QList<RuleDefinition> m_rules;
};

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(RuleEngine &engine)
        : m_engine(engine)
    {
        setWindowTitle(QStringLiteral("稳优 StableTune · C++ Core Preview"));
        resize(1480, 900);

        auto *root = new QWidget;
        root->setObjectName(QStringLiteral("root"));
        setCentralWidget(root);

        auto *shell = new QHBoxLayout(root);
        shell->setContentsMargins(0, 0, 0, 0);
        shell->setSpacing(0);
        shell->addWidget(buildSidebar());
        shell->addWidget(buildContent(), 1);

        setStyleSheet(styleSheetText());
        m_model->setRules(engine.catalog().rules());
        connect(
            m_table->selectionModel(),
            &QItemSelectionModel::currentRowChanged,
            this,
            [this](const QModelIndex &current) {
                showRule(current);
            }
        );
        if (m_model->rowCount() > 0) {
            m_table->selectRow(0);
        }
    }

private:
    QWidget *buildSidebar()
    {
        auto *panel = new QFrame;
        panel->setObjectName(QStringLiteral("sidebar"));
        panel->setFixedWidth(230);
        auto *layout = new QVBoxLayout(panel);
        layout->setContentsMargins(18, 24, 18, 18);
        layout->setSpacing(6);

        auto *brand = new QLabel(QStringLiteral("F"));
        brand->setObjectName(QStringLiteral("brandMark"));
        brand->setAlignment(Qt::AlignCenter);
        brand->setFixedSize(40, 40);
        layout->addWidget(brand);

        auto *title = new QLabel(QStringLiteral("稳优 StableTune"));
        title->setObjectName(QStringLiteral("brandTitle"));
        layout->addWidget(title);
        auto *subtitle = new QLabel(QStringLiteral("C++ Core / Qt 6 Widgets"));
        subtitle->setObjectName(QStringLiteral("brandSubtitle"));
        layout->addWidget(subtitle);
        layout->addSpacing(24);

        for (const QString &item : {
                 QStringLiteral("系统状态"),
                 QStringLiteral("优化分类"),
                 QStringLiteral("历史记录"),
                 QStringLiteral("恢复中心"),
                 QStringLiteral("运行日志"),
                 QStringLiteral("设置"),
             }) {
            auto *button = new QPushButton(item);
            button->setObjectName(QStringLiteral("navButton"));
            button->setCheckable(true);
            button->setChecked(item == QStringLiteral("优化分类"));
            button->setCursor(Qt::PointingHandCursor);
            button->setFixedHeight(40);
            layout->addWidget(button);
        }

        layout->addStretch(1);
        auto *coreBadge = new QLabel(
            QStringLiteral("核心状态\n规则引擎：已连接\n规则：%1")
                .arg(m_engine.catalog().size())
        );
        coreBadge->setObjectName(QStringLiteral("coreBadge"));
        coreBadge->setWordWrap(true);
        layout->addWidget(coreBadge);
        return panel;
    }

    QWidget *buildContent()
    {
        auto *content = new QWidget;
        content->setObjectName(QStringLiteral("content"));
        auto *layout = new QVBoxLayout(content);
        layout->setContentsMargins(26, 22, 26, 20);
        layout->setSpacing(14);

        auto *header = new QHBoxLayout;
        auto *titleBox = new QVBoxLayout;
        auto *title = new QLabel(QStringLiteral("优化分类"));
        title->setObjectName(QStringLiteral("pageTitle"));
        auto *subtitle = new QLabel(
            QStringLiteral("规则执行由 C++ Core 封装，Qt 只负责展示和提交操作")
        );
        subtitle->setObjectName(QStringLiteral("pageSubtitle"));
        titleBox->addWidget(title);
        titleBox->addWidget(subtitle);
        header->addLayout(titleBox);
        header->addStretch(1);
        header->addWidget(badge(QStringLiteral("C++20 Core"), QStringLiteral("info")));
        header->addWidget(badge(QStringLiteral("Qt 6 Widgets"), QStringLiteral("success")));
        header->addWidget(
            badge(
                QStringLiteral("规则 %1").arg(m_engine.catalog().size()),
                QStringLiteral("neutral")
            )
        );
        layout->addLayout(header);

        auto *toolbar = new QHBoxLayout;
        m_search = new QLineEdit;
        m_search->setPlaceholderText(QStringLiteral("搜索规则名称、分类或处理器"));
        m_search->setFixedWidth(320);
        m_search->setClearButtonEnabled(true);
        m_preflight = new QPushButton(QStringLiteral("预检所选"));
        m_preflight->setObjectName(QStringLiteral("primaryButton"));
        m_preflight->setFixedHeight(36);
        m_preflight->setCursor(Qt::PointingHandCursor);
        m_apply = new QPushButton(QStringLiteral("执行所选"));
        m_apply->setObjectName(QStringLiteral("applyButton"));
        m_apply->setFixedHeight(36);
        m_apply->setCursor(Qt::PointingHandCursor);
        m_restoreLast = new QPushButton(QStringLiteral("恢复刚执行项"));
        m_restoreLast->setObjectName(QStringLiteral("secondaryButton"));
        m_restoreLast->setFixedHeight(36);
        m_restoreLast->setCursor(Qt::PointingHandCursor);
        m_restoreLast->setEnabled(false);
        toolbar->addWidget(m_search);
        toolbar->addStretch(1);
        toolbar->addWidget(m_preflight);
        toolbar->addWidget(m_apply);
        toolbar->addWidget(m_restoreLast);
        layout->addLayout(toolbar);

        auto *splitter = new QSplitter(Qt::Horizontal);
        splitter->setChildrenCollapsible(false);
        m_table = new QTableView;
        m_table->setObjectName(QStringLiteral("rulesTable"));
        m_model = new RuleTableModel(m_table);
        m_table->setModel(m_model);
        m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
        m_table->setSelectionMode(QAbstractItemView::SingleSelection);
        m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
        m_table->setAlternatingRowColors(false);
        m_table->setShowGrid(false);
        m_table->verticalHeader()->setVisible(false);
        m_table->verticalHeader()->setDefaultSectionSize(46);
        m_table->horizontalHeader()->setFixedHeight(42);
        m_table->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
        m_table->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
        m_table->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        m_table->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);
        m_table->horizontalHeader()->setSectionResizeMode(4, QHeaderView::ResizeToContents);
        m_table->horizontalHeader()->setSectionResizeMode(5, QHeaderView::ResizeToContents);
        splitter->addWidget(m_table);
        splitter->addWidget(buildDetailPanel());
        splitter->setStretchFactor(0, 1);
        splitter->setStretchFactor(1, 0);
        splitter->setSizes({940, 400});
        layout->addWidget(splitter, 1);

        auto *footer = new QFrame;
        footer->setObjectName(QStringLiteral("footer"));
        auto *footerLayout = new QHBoxLayout(footer);
        footerLayout->setContentsMargins(14, 10, 14, 10);
        m_status = new QLabel(QStringLiteral("规则目录已加载，等待预检。"));
        m_status->setObjectName(QStringLiteral("statusText"));
        footerLayout->addWidget(m_status);
        layout->addWidget(footer);

        connect(m_search, &QLineEdit::textChanged, this, [this](const QString &text) {
            m_table->setVisible(true);
            if (text.trimmed().isEmpty()) {
                for (int row = 0; row < m_model->rowCount(); ++row) {
                    m_table->setRowHidden(row, false);
                }
                return;
            }
            for (int row = 0; row < m_model->rowCount(); ++row) {
                bool match = false;
                for (int column = 0; column < m_model->columnCount(); ++column) {
                    match = match
                        || m_model->index(row, column)
                               .data(Qt::DisplayRole)
                               .toString()
                               .contains(text, Qt::CaseInsensitive);
                }
                m_table->setRowHidden(row, !match);
            }
        });
        connect(m_preflight, &QPushButton::clicked, this, [this] {
            preflightCurrent();
        });
        connect(m_apply, &QPushButton::clicked, this, [this] {
            applyCurrent();
        });
        connect(m_restoreLast, &QPushButton::clicked, this, [this] {
            restoreLast();
        });
        return content;
    }

    QWidget *buildDetailPanel()
    {
        auto *panel = new QFrame;
        panel->setObjectName(QStringLiteral("detailPanel"));
        panel->setMinimumWidth(360);
        auto *layout = new QVBoxLayout(panel);
        layout->setContentsMargins(20, 18, 20, 18);
        layout->setSpacing(10);
        m_detailCategory = new QLabel;
        m_detailCategory->setObjectName(QStringLiteral("detailCategory"));
        m_detailTitle = new QLabel;
        m_detailTitle->setObjectName(QStringLiteral("detailTitle"));
        m_detailTitle->setWordWrap(true);
        m_detailDescription = new QLabel;
        m_detailDescription->setObjectName(QStringLiteral("detailText"));
        m_detailDescription->setWordWrap(true);
        m_detailMeta = new QLabel;
        m_detailMeta->setObjectName(QStringLiteral("detailMeta"));
        m_detailMeta->setWordWrap(true);
        layout->addWidget(m_detailCategory);
        layout->addWidget(m_detailTitle);
        layout->addWidget(m_detailDescription);
        layout->addWidget(divider());
        layout->addWidget(m_detailMeta);
        layout->addStretch(1);
        return panel;
    }

    QLabel *badge(const QString &text, const QString &tone) const
    {
        auto *label = new QLabel(text);
        label->setProperty("badge", tone);
        label->setAlignment(Qt::AlignCenter);
        label->setFixedHeight(25);
        return label;
    }

    QFrame *divider() const
    {
        auto *line = new QFrame;
        line->setObjectName(QStringLiteral("divider"));
        line->setFixedHeight(1);
        return line;
    }

    void showRule(const QModelIndex &index)
    {
        const RuleDefinition *rule = m_model->ruleAt(index);
        if (rule == nullptr) {
            return;
        }
        m_currentRuleId = rule->id;
        m_detailCategory->setText(rule->category);
        m_detailTitle->setText(rule->name);
        m_detailDescription->setText(rule->description);
        m_detailMeta->setText(
            QStringLiteral(
                "处理器：%1\n风险：%2\n需要管理员：%3\n需要重启：%4\n需要输入：%5\n"
                "快照类型：%6\n\n前置条件\n%7"
            )
                .arg(rule->handler)
                .arg(riskLabel(rule->risk))
                .arg(rule->requiresAdmin ? QStringLiteral("是") : QStringLiteral("否"))
                .arg(rule->requiresRestart ? QStringLiteral("是") : QStringLiteral("否"))
                .arg(rule->requiresInput ? QStringLiteral("是") : QStringLiteral("否"))
                .arg(rule->snapshotKind)
                .arg(
                    rule->prerequisites.isEmpty()
                        ? QStringLiteral("无")
                        : QStringLiteral("• ") + rule->prerequisites.join(QStringLiteral("\n• "))
                )
        );
    }

    void preflightCurrent()
    {
        const RuleDefinition *rule = currentRule();
        if (rule == nullptr) {
            return;
        }

        RuleOptions options;
        QString inputError;
        if (
            rule->requiresInput
            && !promptRuleOptions(*rule, &options, this, &inputError)
        ) {
            if (!inputError.isEmpty()) {
                m_status->setText(inputError);
            }
            return;
        }

        OperationContext context;
        context.operationId = QStringLiteral("preview-") + rule->id;
        context.stateRoot = defaultStateRoot();
        const OperationResult result = m_engine.dryRun(rule->id, options, context);
        m_status->setText(
            QStringLiteral("%1 · %2")
                .arg(result.success ? QStringLiteral("预检通过") : QStringLiteral("预检未通过"))
                .arg(result.message)
        );
    }

    void applyCurrent()
    {
        const RuleDefinition *rule = currentRule();
        if (rule == nullptr) {
            return;
        }
        if (rule->requiresAdmin && !SystemFacts::isAdministrator()) {
            QMessageBox::warning(
                this,
                QStringLiteral("需要管理员权限"),
                QStringLiteral("该规则需要以管理员身份运行 稳优 StableTune。")
            );
            return;
        }

        RuleOptions options;
        QString inputError;
        if (
            rule->requiresInput
            && !promptRuleOptions(*rule, &options, this, &inputError)
        ) {
            if (!inputError.isEmpty()) {
                m_status->setText(inputError);
            }
            return;
        }

        OperationContext preflightContext;
        preflightContext.operationId = QStringLiteral("preview-") + rule->id;
        preflightContext.stateRoot = defaultStateRoot();
        const OperationResult preflight = m_engine.dryRun(
            rule->id,
            options,
            preflightContext
        );
        if (!preflight.success) {
            m_status->setText(
                QStringLiteral("执行已阻止 · %1").arg(preflight.message)
            );
            QMessageBox::warning(
                this,
                QStringLiteral("预检未通过"),
                preflight.message
            );
            return;
        }

        if (rule->risk == RuleRisk::Advanced) {
            const QMessageBox::StandardButton choice = QMessageBox::warning(
                this,
                QStringLiteral("高级规则确认"),
                QStringLiteral(
                    "即将执行高级规则：%1\n\n执行前会保存独立快照，并在验证失败时尝试回滚。"
                    "是否继续？"
                ).arg(rule->name),
                QMessageBox::Yes | QMessageBox::No,
                QMessageBox::No
            );
            if (choice != QMessageBox::Yes) {
                return;
            }
        }

        OperationContext context;
        context.stateRoot = defaultStateRoot();
        context.operationId = QStringLiteral("qt-")
            + QUuid::createUuid().toString(QUuid::WithoutBraces);
        const OperationResult result = m_engine.apply(
            rule->id,
            options,
            true,
            context
        );
        m_status->setText(
            QStringLiteral("%1 · %2")
                .arg(result.success ? QStringLiteral("执行完成") : QStringLiteral("执行失败"))
                .arg(result.message)
        );

        if (result.success) {
            m_lastRule = *rule;
            m_lastOptions = options;
            m_lastResult = result;
            m_restoreLast->setEnabled(true);
            QMessageBox::information(
                this,
                QStringLiteral("执行完成"),
                QStringLiteral("%1\n\n快照：%2")
                    .arg(result.message, result.snapshotPath)
            );
        } else {
            QMessageBox::critical(
                this,
                QStringLiteral("执行失败"),
                result.message
            );
        }
    }

    void restoreLast()
    {
        if (!m_lastResult.success) {
            return;
        }

        OperationContext context;
        context.stateRoot = defaultStateRoot();
        context.operationId = QStringLiteral("restore-")
            + QUuid::createUuid().toString(QUuid::WithoutBraces);
        const OperationResult result = m_engine.restore(
            m_lastRule,
            m_lastOptions,
            m_lastResult.snapshot,
            false,
            context
        );
        m_status->setText(
            QStringLiteral("%1 · %2")
                .arg(result.success ? QStringLiteral("恢复完成") : QStringLiteral("恢复失败"))
                .arg(result.message)
        );
        if (result.success) {
            m_lastResult = {};
            m_restoreLast->setEnabled(false);
            QMessageBox::information(
                this,
                QStringLiteral("恢复完成"),
                result.message
            );
        } else {
            QMessageBox::critical(
                this,
                QStringLiteral("恢复失败"),
                result.message
            );
        }
    }

    const RuleDefinition *currentRule() const
    {
        return m_engine.catalog().find(m_currentRuleId);
    }

    QString styleSheetText() const
    {
        return QStringLiteral(R"(
            * {
                font-family: "Microsoft YaHei UI", "Segoe UI";
                font-size: 13px;
                color: #1f2933;
            }
            QWidget#root, QWidget#content {
                background: #f3f5f7;
            }
            QFrame#sidebar {
                background: #20262c;
                border: none;
            }
            QLabel#brandMark {
                background: #087f8c;
                color: white;
                border-radius: 8px;
                font-size: 19px;
                font-weight: 700;
            }
            QLabel#brandTitle {
                color: #f7f9fa;
                font-size: 16px;
                font-weight: 700;
                margin-top: 8px;
            }
            QLabel#brandSubtitle {
                color: #9da8b2;
                font-size: 11px;
            }
            QPushButton#navButton {
                color: #aeb7c1;
                background: transparent;
                border: none;
                border-radius: 7px;
                padding: 0 12px;
                text-align: left;
                font-weight: 600;
            }
            QPushButton#navButton:hover {
                background: #2b333b;
                color: white;
            }
            QPushButton#navButton:checked {
                background: #2f3a42;
                color: #eafbf8;
                border-left: 3px solid #5eead4;
            }
            QLabel#coreBadge {
                color: #b8c3cc;
                background: #293138;
                border: 1px solid #35414a;
                border-radius: 8px;
                padding: 12px;
                line-height: 1.5;
            }
            QLabel#pageTitle {
                font-size: 24px;
                font-weight: 700;
                color: #17212b;
            }
            QLabel#pageSubtitle {
                color: #697586;
                font-size: 12px;
            }
            QLabel[badge] {
                border-radius: 6px;
                padding: 1px 9px;
                font-size: 11px;
                font-weight: 650;
            }
            QLabel[badge="neutral"] {
                background: #eef1f4;
                color: #52606d;
                border: 1px solid #dce2e8;
            }
            QLabel[badge="info"] {
                background: #eaf1fb;
                color: #315e9e;
                border: 1px solid #c9d9ef;
            }
            QLabel[badge="success"] {
                background: #e9f7ef;
                color: #18794e;
                border: 1px solid #c8e8d6;
            }
            QLineEdit {
                background: white;
                border: 1px solid #cfd7de;
                border-radius: 6px;
                padding: 6px 11px;
                min-height: 24px;
            }
            QLineEdit:focus {
                border-color: #087f8c;
            }
            QPushButton#primaryButton {
                background: #087f8c;
                color: white;
                border: 1px solid #087f8c;
                border-radius: 6px;
                padding: 0 18px;
                font-weight: 650;
            }
            QPushButton#primaryButton:hover {
                background: #086d78;
            }
            QPushButton#applyButton {
                background: #173f35;
                color: white;
                border: 1px solid #173f35;
                border-radius: 6px;
                padding: 0 18px;
                font-weight: 650;
            }
            QPushButton#applyButton:hover {
                background: #0f3028;
            }
            QPushButton#secondaryButton {
                background: white;
                color: #315e9e;
                border: 1px solid #bfd0df;
                border-radius: 6px;
                padding: 0 14px;
                font-weight: 600;
            }
            QPushButton#secondaryButton:hover {
                background: #f3f8fc;
            }
            QPushButton#secondaryButton:disabled {
                color: #9aa6b2;
                border-color: #dde3e8;
                background: #f6f7f8;
            }
            QComboBox, QLineEdit, QCheckBox {
                min-height: 28px;
            }
            QComboBox {
                background: white;
                border: 1px solid #cfd7de;
                border-radius: 6px;
                padding: 3px 9px;
            }
            QTableView#rulesTable, QFrame#detailPanel {
                background: white;
                border: 1px solid #dce2e8;
                border-radius: 8px;
            }
            QTableView#rulesTable {
                selection-background-color: #edf6f6;
                selection-color: #1f2933;
                outline: 0;
            }
            QTableView#rulesTable::item {
                border-bottom: 1px solid #e9edf1;
                padding: 0 8px;
            }
            QHeaderView::section {
                background: #f8fafb;
                color: #66727e;
                border: none;
                border-bottom: 1px solid #dce2e8;
                padding: 0 8px;
                font-size: 11px;
                font-weight: 650;
            }
            QLabel#detailCategory {
                color: #087f8c;
                font-size: 11px;
                font-weight: 700;
            }
            QLabel#detailTitle {
                font-size: 21px;
                font-weight: 700;
                color: #17212b;
            }
            QLabel#detailText, QLabel#detailMeta {
                color: #596675;
                font-size: 12px;
                line-height: 1.5;
            }
            QFrame#divider {
                background: #e9edf1;
                border: none;
            }
            QFrame#footer {
                background: #ebf2f1;
                border: 1px solid #d3e5e2;
                border-radius: 8px;
            }
            QLabel#statusText {
                color: #35605a;
                font-size: 11px;
            }
        )");
    }

    RuleEngine &m_engine;
    RuleTableModel *m_model = nullptr;
    QTableView *m_table = nullptr;
    QLineEdit *m_search = nullptr;
    QPushButton *m_preflight = nullptr;
    QPushButton *m_apply = nullptr;
    QPushButton *m_restoreLast = nullptr;
    QLabel *m_status = nullptr;
    QLabel *m_detailCategory = nullptr;
    QLabel *m_detailTitle = nullptr;
    QLabel *m_detailDescription = nullptr;
    QLabel *m_detailMeta = nullptr;
    QString m_currentRuleId;
    RuleDefinition m_lastRule;
    RuleOptions m_lastOptions;
    OperationResult m_lastResult;
};

}  // namespace

int main(int argc, char *argv[])
{
    QApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("稳优 StableTune"));
    application.setOrganizationName(QStringLiteral("StableTune"));
    application.setStyle(QStringLiteral("Fusion"));

    QString catalogPath = defaultCatalogPath();
    if (catalogPath.isEmpty()) {
        QMessageBox::critical(
            nullptr,
            QStringLiteral("稳优 StableTune"),
            QStringLiteral("Unable to locate rules/catalog.json.")
        );
        return 2;
    }

    QString error;
    std::unique_ptr<RuleEngine> engine = RuleEngine::createDefault(
        catalogPath,
        defaultStateRoot(),
        &error
    );
    if (engine == nullptr) {
        QMessageBox::critical(
            nullptr,
            QStringLiteral("稳优 StableTune"),
            QStringLiteral("Core initialization failed:\n%1").arg(error)
        );
        return 3;
    }

    MainWindow window(*engine);
    window.show();
    const QStringList arguments = application.arguments();
    const qsizetype screenshotIndex = arguments.indexOf(QStringLiteral("--screenshot"));
    if (
        screenshotIndex >= 0
        && screenshotIndex + 1 < arguments.size()
    ) {
        const QString screenshotPath = arguments.at(screenshotIndex + 1);
        QTimer::singleShot(500, &window, [&application, &window, screenshotPath] {
            window.grab().save(screenshotPath);
            application.quit();
        });
    } else if (arguments.contains(QStringLiteral("--smoke-test"))) {
        QTimer::singleShot(750, &application, &QCoreApplication::quit);
    }
    return application.exec();
}
