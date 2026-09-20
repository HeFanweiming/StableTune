#include "felix/core/windows/registry.h"

#include <QJsonArray>
#include <QJsonValue>

#ifdef FELIX_PLATFORM_WINDOWS
#include <windows.h>
#endif

#include <stdexcept>
#include <iterator>

namespace felix::core::windows {
namespace {

#ifdef FELIX_PLATFORM_WINDOWS

struct RegistryPath {
    HKEY root = nullptr;
    QString subKey;
};

RegistryPath parseRegistryPath(const QString &path)
{
    QString normalized = path.trimmed();
    normalized.replace(QStringLiteral(":\\"), QStringLiteral("\\"));
    normalized.replace(QLatin1Char('/'), QLatin1Char('\\'));

    struct RootMapping {
        const wchar_t *name;
        HKEY value;
    };
    const RootMapping roots[] = {
        {L"HKLM", HKEY_LOCAL_MACHINE},
        {L"HKEY_LOCAL_MACHINE", HKEY_LOCAL_MACHINE},
        {L"HKCU", HKEY_CURRENT_USER},
        {L"HKEY_CURRENT_USER", HKEY_CURRENT_USER},
        {L"HKCR", HKEY_CLASSES_ROOT},
        {L"HKEY_CLASSES_ROOT", HKEY_CLASSES_ROOT},
        {L"HKU", HKEY_USERS},
        {L"HKEY_USERS", HKEY_USERS},
        {L"HKCC", HKEY_CURRENT_CONFIG},
        {L"HKEY_CURRENT_CONFIG", HKEY_CURRENT_CONFIG},
    };

    for (const RootMapping &mapping : roots) {
        const QString prefix = QString::fromWCharArray(mapping.name);
        if (normalized.compare(prefix, Qt::CaseInsensitive) == 0) {
            return RegistryPath{mapping.value, {}};
        }
        if (normalized.startsWith(prefix + QLatin1Char('\\'), Qt::CaseInsensitive)) {
            return RegistryPath{
                mapping.value,
                normalized.mid(prefix.size() + 1),
            };
        }
    }

    throw std::runtime_error("Unsupported registry root in path.");
}

QString windowsError(DWORD code)
{
    wchar_t *buffer = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM
            | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        code,
        0,
        reinterpret_cast<LPWSTR>(&buffer),
        0,
        nullptr
    );
    QString message = length > 0 && buffer != nullptr
        ? QString::fromWCharArray(buffer, static_cast<int>(length)).trimmed()
        : QStringLiteral("Windows error %1").arg(code);
    if (buffer != nullptr) {
        LocalFree(buffer);
    }
    return message;
}

void throwWindowsError(const QString &operation, DWORD code)
{
    throw std::runtime_error(
        QStringLiteral("%1 failed: %2").arg(operation, windowsError(code)).toUtf8().constData()
    );
}

DWORD registryTypeFromName(const QString &kind)
{
    const QString normalized = kind.trimmed().toLower();
    if (normalized == QStringLiteral("dword")) {
        return REG_DWORD;
    }
    if (normalized == QStringLiteral("qword")) {
        return REG_QWORD;
    }
    if (normalized == QStringLiteral("binary")) {
        return REG_BINARY;
    }
    if (normalized == QStringLiteral("multistring")) {
        return REG_MULTI_SZ;
    }
    if (normalized == QStringLiteral("expandstring")) {
        return REG_EXPAND_SZ;
    }
    if (normalized == QStringLiteral("string")) {
        return REG_SZ;
    }
    throw std::runtime_error("Unsupported registry value kind.");
}

QString registryTypeName(DWORD type)
{
    switch (type) {
    case REG_DWORD:
    case REG_DWORD_BIG_ENDIAN:
        return QStringLiteral("DWord");
    case REG_QWORD:
        return QStringLiteral("QWord");
    case REG_BINARY:
        return QStringLiteral("Binary");
    case REG_MULTI_SZ:
        return QStringLiteral("MultiString");
    case REG_EXPAND_SZ:
        return QStringLiteral("ExpandString");
    case REG_SZ:
        return QStringLiteral("String");
    default:
        return QStringLiteral("Unknown");
    }
}

QString multiStringFromBytes(const QByteArray &bytes)
{
    if (bytes.isEmpty()) {
        return {};
    }
    const int characterCount = bytes.size() / static_cast<int>(sizeof(wchar_t));
    QString result = QString::fromWCharArray(
        reinterpret_cast<const wchar_t *>(bytes.constData()),
        characterCount
    );
    result.replace(QChar::Null, QLatin1Char('\n'));
    while (result.endsWith(QLatin1Char('\n'))) {
        result.chop(1);
    }
    return result;
}

QVariant valueFromBytes(DWORD type, const QByteArray &bytes)
{
    switch (type) {
    case REG_DWORD:
    case REG_DWORD_BIG_ENDIAN: {
        if (bytes.size() < static_cast<int>(sizeof(DWORD))) {
            return 0U;
        }
        const auto *data = reinterpret_cast<const DWORD *>(bytes.constData());
        return static_cast<quint32>(*data);
    }
    case REG_QWORD: {
        if (bytes.size() < static_cast<int>(sizeof(quint64))) {
            return QVariant::fromValue<qulonglong>(0);
        }
        const auto *data = reinterpret_cast<const quint64 *>(bytes.constData());
        return QVariant::fromValue<qulonglong>(*data);
    }
    case REG_SZ:
    case REG_EXPAND_SZ: {
        QString text = QString::fromWCharArray(
            reinterpret_cast<const wchar_t *>(bytes.constData()),
            bytes.size() / static_cast<int>(sizeof(wchar_t))
        );
        const qsizetype terminator = text.indexOf(QChar::Null);
        if (terminator >= 0) {
            text.truncate(terminator);
        }
        return text;
    }
    case REG_MULTI_SZ: {
        QStringList values;
        for (const QString &value : multiStringFromBytes(bytes).split(QLatin1Char('\n'))) {
            if (!value.isEmpty()) {
                values.append(value);
            }
        }
        return values;
    }
    case REG_BINARY:
        return bytes;
    default:
        return bytes;
    }
}

QByteArray bytesFromVariant(DWORD type, const QVariant &value)
{
    switch (type) {
    case REG_DWORD:
    case REG_DWORD_BIG_ENDIAN: {
        const DWORD number = static_cast<DWORD>(value.toUInt());
        return QByteArray(reinterpret_cast<const char *>(&number), sizeof(number));
    }
    case REG_QWORD: {
        const quint64 number = value.toULongLong();
        return QByteArray(reinterpret_cast<const char *>(&number), sizeof(number));
    }
    case REG_SZ:
    case REG_EXPAND_SZ: {
        const QString text = value.toString();
        return QByteArray(
            reinterpret_cast<const char *>(text.utf16()),
            (text.size() + 1) * static_cast<int>(sizeof(wchar_t))
        );
    }
    case REG_MULTI_SZ: {
        QStringList values;
        if (value.metaType().id() == QMetaType::QStringList) {
            values = value.toStringList();
        } else {
            values = value.toString().split(QLatin1Char('\n'));
        }

        QByteArray bytes;
        for (const QString &entry : values) {
            bytes.append(
                reinterpret_cast<const char *>(entry.utf16()),
                entry.size() * static_cast<int>(sizeof(wchar_t))
            );
            bytes.append(static_cast<char>(0));
            bytes.append(static_cast<char>(0));
        }
        bytes.append(static_cast<char>(0));
        bytes.append(static_cast<char>(0));
        return bytes;
    }
    case REG_BINARY: {
        if (value.metaType().id() == QMetaType::QByteArray) {
            return value.toByteArray();
        }
        return QByteArray::fromBase64(value.toString().toLatin1());
    }
    default:
        return {};
    }
}

#endif

}  // namespace

QJsonObject RegistryValue::toJson() const
{
    QJsonObject object{
        {QStringLiteral("exists"), exists},
    };
    if (!exists) {
        object.insert(QStringLiteral("kind"), QJsonValue::Null);
        object.insert(QStringLiteral("value"), QJsonValue::Null);
        return object;
    }

    object.insert(QStringLiteral("kind"), kind);
    if (kind == QStringLiteral("Binary")) {
        object.insert(QStringLiteral("valueEncoding"), QStringLiteral("base64"));
        object.insert(
            QStringLiteral("value"),
            QString::fromLatin1(value.toByteArray().toBase64())
        );
    } else if (kind == QStringLiteral("MultiString")) {
        object.insert(
            QStringLiteral("value"),
            QJsonArray::fromStringList(value.toStringList())
        );
    } else if (kind == QStringLiteral("QWord")) {
        object.insert(QStringLiteral("value"), QString::number(value.toULongLong()));
        object.insert(QStringLiteral("valueEncoding"), QStringLiteral("decimal-string"));
    } else if (
        kind == QStringLiteral("DWord")
        || value.metaType().id() == QMetaType::Int
        || value.metaType().id() == QMetaType::UInt
    ) {
        object.insert(
            QStringLiteral("value"),
            static_cast<double>(value.toUInt())
        );
    } else {
        object.insert(QStringLiteral("value"), value.toString());
    }
    return object;
}

RegistryValue RegistryValue::fromJson(const QJsonObject &object)
{
    RegistryValue value;
    value.exists = object.value(QStringLiteral("exists")).toBool(false);
    if (!value.exists) {
        return value;
    }

    value.kind = object.value(QStringLiteral("kind")).toString();
    const QJsonValue jsonValue = object.value(QStringLiteral("value"));
    const QString encoding = object.value(QStringLiteral("valueEncoding")).toString();

    if (value.kind == QStringLiteral("Binary")) {
        value.value = QByteArray::fromBase64(jsonValue.toString().toLatin1());
    } else if (value.kind == QStringLiteral("MultiString")) {
        QStringList entries;
        for (const QJsonValue &entry : jsonValue.toArray()) {
            entries.append(entry.toString());
        }
        value.value = entries;
    } else if (value.kind == QStringLiteral("QWord") || encoding == QStringLiteral("decimal-string")) {
        value.value = QVariant::fromValue<qulonglong>(jsonValue.toString().toULongLong());
    } else if (value.kind == QStringLiteral("DWord")) {
        value.value = jsonValue.toVariant().toUInt();
    } else {
        value.value = jsonValue.toString();
    }
    return value;
}

RegistryValue RegistryStore::read(const QString &path, const QString &name)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const RegistryPath parsed = parseRegistryPath(path);
    HKEY key = nullptr;
    const LSTATUS openStatus = RegOpenKeyExW(
        parsed.root,
        reinterpret_cast<LPCWSTR>(parsed.subKey.utf16()),
        0,
        KEY_READ,
        &key
    );
    if (openStatus == ERROR_FILE_NOT_FOUND || openStatus == ERROR_PATH_NOT_FOUND) {
        return {};
    }
    if (openStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegOpenKeyExW"), openStatus);
    }

    DWORD type = 0;
    DWORD size = 0;
    const LSTATUS queryStatus = RegQueryValueExW(
        key,
        name.isEmpty() ? nullptr : reinterpret_cast<LPCWSTR>(name.utf16()),
        nullptr,
        &type,
        nullptr,
        &size
    );
    if (queryStatus == ERROR_FILE_NOT_FOUND || queryStatus == ERROR_PATH_NOT_FOUND) {
        RegCloseKey(key);
        return {};
    }
    if (queryStatus != ERROR_SUCCESS) {
        RegCloseKey(key);
        throwWindowsError(QStringLiteral("RegQueryValueExW"), queryStatus);
    }

    QByteArray bytes(static_cast<int>(size), Qt::Uninitialized);
    const LSTATUS readStatus = RegQueryValueExW(
        key,
        name.isEmpty() ? nullptr : reinterpret_cast<LPCWSTR>(name.utf16()),
        nullptr,
        &type,
        reinterpret_cast<LPBYTE>(bytes.data()),
        &size
    );
    RegCloseKey(key);
    if (readStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegQueryValueExW"), readStatus);
    }
    bytes.resize(static_cast<int>(size));

    RegistryValue result;
    result.exists = true;
    result.kind = registryTypeName(type);
    result.value = valueFromBytes(type, bytes);
    return result;
#else
    Q_UNUSED(path);
    Q_UNUSED(name);
    return {};
#endif
}

void RegistryStore::write(
    const QString &path,
    const QString &name,
    const QString &kind,
    const QVariant &value
)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const RegistryPath parsed = parseRegistryPath(path);
    HKEY key = nullptr;
    DWORD disposition = 0;
    const LSTATUS createStatus = RegCreateKeyExW(
        parsed.root,
        reinterpret_cast<LPCWSTR>(parsed.subKey.utf16()),
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        &key,
        &disposition
    );
    if (createStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegCreateKeyExW"), createStatus);
    }

    const DWORD type = registryTypeFromName(kind);
    const QByteArray bytes = bytesFromVariant(type, value);
    const LSTATUS setStatus = RegSetValueExW(
        key,
        name.isEmpty() ? nullptr : reinterpret_cast<LPCWSTR>(name.utf16()),
        0,
        type,
        reinterpret_cast<const BYTE *>(bytes.constData()),
        static_cast<DWORD>(bytes.size())
    );
    RegCloseKey(key);
    if (setStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegSetValueExW"), setStatus);
    }
#else
    Q_UNUSED(path);
    Q_UNUSED(name);
    Q_UNUSED(kind);
    Q_UNUSED(value);
#endif
}

void RegistryStore::remove(const QString &path, const QString &name, bool ignoreMissing)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const RegistryPath parsed = parseRegistryPath(path);
    HKEY key = nullptr;
    const LSTATUS openStatus = RegOpenKeyExW(
        parsed.root,
        reinterpret_cast<LPCWSTR>(parsed.subKey.utf16()),
        0,
        KEY_SET_VALUE,
        &key
    );
    if (openStatus == ERROR_FILE_NOT_FOUND || openStatus == ERROR_PATH_NOT_FOUND) {
        if (ignoreMissing) {
            return;
        }
        throw std::runtime_error("Registry key was not found.");
    }
    if (openStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegOpenKeyExW"), openStatus);
    }

    const LSTATUS deleteStatus = RegDeleteValueW(
        key,
        name.isEmpty() ? nullptr : reinterpret_cast<LPCWSTR>(name.utf16())
    );
    RegCloseKey(key);
    if (
        deleteStatus == ERROR_FILE_NOT_FOUND
        || deleteStatus == ERROR_PATH_NOT_FOUND
    ) {
        if (ignoreMissing) {
            return;
        }
        throw std::runtime_error("Registry value was not found.");
    }
    if (deleteStatus != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegDeleteValueW"), deleteStatus);
    }
#else
    Q_UNUSED(path);
    Q_UNUSED(name);
    Q_UNUSED(ignoreMissing);
#endif
}

bool RegistryStore::keyExists(const QString &path)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const RegistryPath parsed = parseRegistryPath(path);
    HKEY key = nullptr;
    const LSTATUS status = RegOpenKeyExW(
        parsed.root,
        reinterpret_cast<LPCWSTR>(parsed.subKey.utf16()),
        0,
        KEY_READ,
        &key
    );
    if (status == ERROR_SUCCESS) {
        RegCloseKey(key);
        return true;
    }
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
        return false;
    }
    throwWindowsError(QStringLiteral("RegOpenKeyExW"), status);
#else
    Q_UNUSED(path);
    return false;
#endif
}

QStringList RegistryStore::subKeys(const QString &path)
{
#ifdef FELIX_PLATFORM_WINDOWS
    const RegistryPath parsed = parseRegistryPath(path);
    HKEY key = nullptr;
    const LSTATUS status = RegOpenKeyExW(
        parsed.root,
        reinterpret_cast<LPCWSTR>(parsed.subKey.utf16()),
        0,
        KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE,
        &key
    );
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
        return {};
    }
    if (status != ERROR_SUCCESS) {
        throwWindowsError(QStringLiteral("RegOpenKeyExW"), status);
    }

    QStringList names;
    DWORD index = 0;
    while (true) {
        wchar_t name[512]{};
        DWORD length = static_cast<DWORD>(std::size(name));
        const LSTATUS enumStatus = RegEnumKeyExW(
            key,
            index,
            name,
            &length,
            nullptr,
            nullptr,
            nullptr,
            nullptr
        );
        if (enumStatus == ERROR_NO_MORE_ITEMS) {
            break;
        }
        if (enumStatus != ERROR_SUCCESS) {
            RegCloseKey(key);
            throwWindowsError(QStringLiteral("RegEnumKeyExW"), enumStatus);
        }
        names.append(QString::fromWCharArray(name, static_cast<int>(length)));
        ++index;
    }
    RegCloseKey(key);
    return names;
#else
    Q_UNUSED(path);
    return {};
#endif
}

bool RegistryStore::equivalent(const RegistryValue &left, const RegistryValue &right)
{
    return registryValueComparable(left) == registryValueComparable(right);
}

QString normalizeRegistryPath(const QString &path)
{
    QString normalized = path.trimmed();
    normalized.replace(QStringLiteral(":\\"), QStringLiteral("\\"));
    normalized.replace(QLatin1Char('/'), QLatin1Char('\\'));
    return normalized;
}

QString registryValueComparable(const RegistryValue &value)
{
    if (!value.exists) {
        return QStringLiteral("<missing>");
    }
    if (value.kind == QStringLiteral("Binary")) {
        return value.kind + QLatin1Char(':')
            + QString::fromLatin1(value.value.toByteArray().toBase64());
    }
    if (value.kind == QStringLiteral("MultiString")) {
        return value.kind + QLatin1Char(':')
            + value.value.toStringList().join(QChar(0x1f));
    }
    return value.kind + QLatin1Char(':') + value.value.toString();
}

}  // namespace felix::core::windows
