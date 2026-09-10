# XcodeCleaner — дизайн

Дата: 2026-09-09

## Цель

macOS-приложение с UI, заменяющее скрипт `~/Desktop/Xcode Cleanup.command`.
Чистит регенерируемые данные Xcode и симуляторов, старые Archives, неиспользуемые
Xcode.app и toolchains, проектные кэши, а также управляет маунтами Arcadia:
монтирует новые, размонтирует и удаляет store размонтированных.

Целевая машина: macOS 26, Xcode 26.2, Swift 6.2, arc в `PATH`.

## Сборка

Вариант A: SwiftPM-пакет без Xcode-проекта.

- `Package.swift`: один executable target `XcodeCleaner` (SwiftUI, macOS 15+),
  один test target `XcodeCleanerTests`.
- `build.sh`: `swift build -c release`, сборка `XcodeCleaner.app`
  (`Contents/MacOS/XcodeCleaner`, `Contents/Info.plist`, `Contents/Resources/AppIcon.icns`
  из `Assets/AppIcon.png` через `iconutil`), ad-hoc подпись `codesign -s -`,
  копирование `.app` в `~/Desktop`.
- App Sandbox не используется: нужен доступ к `~/Library`, `/Applications`,
  запуск `xcrun`, `arc`, `df`.
- Исходник: `~/Developer/XcodeCleaner`, git-репозиторий.

## Структура UI

Одно окно, `NavigationSplitView`, боковая панель с тремя разделами.

### Шапка (общая для всех разделов)

Полоса заполнения диска и подпись «Свободно X из Y». Справа «Освободится» —
сумма размеров отмеченного в текущем разделе, появляется только когда что-то
выбрано. После очистки показывается фактически освобождённое место.

### Раздел «Xcode»

Одна строка списка — одна категория, а не путь к папке: чекбокс, заголовок,
одна строка про последствия и размер. Стрелка раскрывает конкретные элементы
внутри категории с отдельными чекбоксами; по умолчанию категория свёрнута.

Категории разбиты на две группы: «Восстановится само» и «Не восстановится
автоматически».

Сканирование двухфазное. Сначала строится структура без обхода дерева, список
появляется сразу. Затем размеры считаются параллельно и подставляются в строки
по мере готовности; до готовности в строке стоит индикатор.

| Категория | Пути / источник | Деструктивно |
|---|---|---|
| Кэши сборки | `~/Library/Developer/Xcode/DerivedData`, `~/Library/Caches/com.apple.dt.Xcode` | нет |
| Превью и документация | `~/Library/Developer/Xcode/UserData/Previews`, `.../DocumentationCache` | нет |
| DeviceSupport | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport` | нет |
| CoreSimulator и SwiftPM | `~/Library/Developer/CoreSimulator/Caches`, `~/Library/Caches/com.apple.CoreSimulator`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/Logs/CoreSimulator` | нет |
| Симуляторы | режим-переключатель: только недоступные / стереть все / удалить все / удалить все + runtimes | всё кроме первого |
| Archives старше N дней | `~/Library/Developer/Xcode/Archives/**/*.xcarchive`, слайдер N (по умолчанию 30), список конкретных архивов | да |
| Старые Xcode | `/Applications/Xcode*.app` кроме результата `xcode-select -p`; каждый отдельным чекбоксом | да |
| Toolchains | `~/Library/Developer/Toolchains/*.xctoolchain` кроме симлинка `swift-latest` и его цели; каждый отдельным чекбоксом | да |
| Проектные кэши | `~/.cache/tuist`; для каждого маунта Arcadia со статусом `mounted`: `mobile/saft/ios/Tuist/.build`, `mobile/saft/ios/Derived`, `mobile/saft/ios/DerivedData` | нет |

Проектные кэши ищутся только проверкой существования фиксированных путей.
Рекурсивный обход FUSE-маунтов запрещён; размер проектных кэшей внутри
маунта считается обходом только этих подпапок.

### Раздел «Arcadia»

Таблица из `arc mount --list --json` с колонкой-чекбоксом: имя маунта, статус
(`mounted`/`unmounted`), дата последнего использования, размер store. Основной
маунт `~/arcadia` показывается с замком и без чекбокса.

Дата последнего использования — `modificationDate` папки `<store>/.arc`, с
откатом на сам store. Она отражает реальную работу с веткой, тогда как mtime
корня store не меняется после создания.

Создание маунтов в приложении не поддерживается: это чистильщик.

Единственное действие — «Удалить выбранные». Оно снимает всё, что связано с
маунтом:

- если маунт смонтирован, `arc unmount <path>`; ответ «Repository seems to be
  already unmounted» не считается ошибкой, потому что список арк может быть
  устаревшим;
- `arc unmount --forget <path>`; его неудача не прерывает операцию;
- если store всё ещё существует, он удаляется напрямую, но только внутри
  `<home>/.arc/stores/`;
- пустая папка маунта снимается через `rmdir(2)`.

Операция считается неуспешной, только если и `--forget` не сработал, и store
удалить не удалось.

Все `arc`-команды запускаются с рабочей директорией `~`.

### Раздел «Лог»

Живой построчный вывод всех команд и итог. Файл лога
`~/Desktop/Xcode Cleanup Logs/cleanup-<дата>.log`.

### Подтверждение

Кнопка внизу окна действует только на текущий раздел: на вкладке Xcode она
чистит категории Xcode, на вкладке Arcadia удаляет отмеченные маунты. Она
открывает модальный лист: список пунктов с
размерами, суммарный размер, отдельный чекбокс «Понимаю, что данные не
попадут в Корзину» для деструктивных пунктов; без него кнопка «Удалить»
заблокирована. Кодовые фразы из скрипта не используются.

## Архитектура

- `CleanupCategory` (enum): описание категорий как данных: заголовок, пути,
  флаг деструктивности, способ удаления.
- `CleanupItem` (struct): конкретный путь или simctl-операция, категория,
  размер, статус выполнения (`pending`/`done`/`failed(String)`).
- `DiskSpace` (struct): свободно/занято/всего, читается из `URLResourceValues`.
- `Scanner` (Sendable struct): только чтение. Строит `[CleanupItem]` и `[ArcMount]`
  из allowlist путей, `xcrun simctl list -j`, `xcrun simctl runtime list -j`,
  `xcode-select -p`, `arc mount --list --json`. Размеры считает в фоне.
- `Cleaner` (Sendable struct): единственное место удаления. Правила из скрипта:
  путь в allowlist, не симлинк, содержимое каталога удаляется по элементам,
  элемент на другом `st_dev` пропускается с ошибкой. Archives, Xcode.app и
  toolchains отправляются в Корзину через `FileManager.trashItem`; кэши
  удаляются напрямую.
- `ArcMountManager` (Sendable struct без состояния): mount/unmount/forget/rmdir(2) через `CommandRunner`; размеры store считаются вместе с остальными в `Scanner.measureSizes(for:onSize:)`.
- `CommandRunner` (protocol + `ProcessCommandRunner`): запуск `Process`,
  построчный стриминг stdout/stderr в лог через `@Sendable` callback.
- `AppModel` (`@Observable`, `@MainActor`): состояние UI, выбор, диск,
  прогресс, лог.

Порядок выполнения очистки: проверка, что `Xcode`, `Simulator`, `xcodebuild`,
`xctest` не запущены (`pgrep -x`), иначе остановка с сообщением;
`simctl shutdown all`; кэши; `simctl delete unavailable`;
`simctl runtime dyld_shared_cache remove --all`; выбранный режим симуляторов;
Archives; Xcode.app; toolchains; проектные кэши; `sync`; замер диска.
Ошибка одного пункта не останавливает прогон.

## Тесты

XCTest, target `XcodeCleanerTests`:

- Парсинг фикстур JSON `simctl list`, `simctl runtime list`, `arc mount --list`.
- `Cleaner` во временной папке: удаляет содержимое allowlist-каталога,
  не удаляет сам каталог, пропускает симлинки, отказывает пути вне allowlist.
- Фильтр Archives по возрасту.
- Выбор «старых» Xcode и toolchains по активному `xcode-select` и `swift-latest`.
- `CommandRunner` подменяется фейком; реальные `arc`/`simctl` в тестах не
  вызываются.

Ручная проверка: `./build.sh`, запуск `.app`, скан, удаление одного тестового
unmounted-маунта, сверка «Освободится» с фактическим df.

## Вне scope

Menu bar-режим, автозапуск по расписанию, нотаризация, распространение.
