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

Панель диска домашнего тома: «Свободно», «Занято», «Всего» из
`URLResourceValues` (`volumeAvailableCapacityForImportantUsageKey`,
`volumeTotalCapacityKey`). «Освободится: X» — сумма размеров отмеченных
пунктов во всех разделах, пересчитывается при каждом изменении выбора.
После очистки показываем «было → стало» по фактическому замеру.

### Раздел «Xcode»

Список категорий, каждая с чекбоксом и размером, размеры считаются в фоне при
открытии и по кнопке «Пересканировать».

| Категория | Пути / источник | Деструктивно |
|---|---|---|
| Кэши Xcode | `~/Library/Developer/Xcode/DerivedData`, `.../DocumentationCache`, `.../UserData/Previews`, `~/Library/Caches/com.apple.dt.Xcode` | нет |
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

Таблица из `arc mount --list --json`: путь маунта, статус (`mounted`/
`unmounted`), размер store, метка «общий object store», если `object-store`
совпадает с object store основного маунта `~/arcadia`. Основной маунт
показывается без чекбокса.

Кнопки:

- **Смонтировать новую.** Поле имени, путь `~/arcadia_<имя>`. Валидация: имя
  без `/`, пробелов, не пустое; папка не существует или пуста. Команды:
  `mkdir -p <путь>`, затем
  `arc mount -m <путь> --object-store <object store основного> --override-object-store`.
  Ветки и checkout приложение не делает.
- **Размонтировать выбранные.** `arc unmount <путь>` для выбранных `mounted`.
  При ошибке показать вывод arc и кнопку «Повторить с --force».
- **Удалить выбранные.** Для `mounted` сначала `arc unmount <путь>`, затем
  `arc unmount --forget <путь>`, затем `rmdir <путь>`. Если папка непуста,
  `rmdir` не выполняется, факт пишется в лог. Пункт деструктивный.

Все `arc`-команды запускаются с рабочей директорией `~`.

### Раздел «Лог»

Живой построчный вывод всех команд и итог. Файл лога
`~/Desktop/Xcode Cleanup Logs/cleanup-<дата>.log`.

### Подтверждение

Кнопка «Очистить выбранное» открывает модальный лист: список пунктов с
размерами, суммарный размер, отдельный чекбокс «Понимаю, что данные не
попадут в Корзину» для деструктивных пунктов; без него кнопка «Удалить»
заблокирована. Кодовые фразы из скрипта не используются.

## Архитектура

- `CleanupCategory` (enum): описание категорий как данных: заголовок, пути,
  флаг деструктивности, способ удаления.
- `CleanupItem` (struct): конкретный путь или simctl-операция, категория,
  размер, статус выполнения (`pending`/`done`/`failed(String)`).
- `DiskSpace` (struct): свободно/занято/всего, читается из `URLResourceValues`.
- `Scanner` (actor): только чтение. Строит `[CleanupItem]` и `[ArcMount]`
  из allowlist путей, `xcrun simctl list -j`, `xcrun simctl runtime list -j`,
  `xcode-select -p`, `arc mount --list --json`. Размеры считает в фоне.
- `Cleaner` (actor): единственное место удаления. Правила из скрипта:
  путь в allowlist, не симлинк, содержимое каталога удаляется по элементам,
  элемент на другом `st_dev` пропускается с ошибкой. Archives, Xcode.app и
  toolchains отправляются в Корзину через `FileManager.trashItem`; кэши
  удаляются напрямую.
- `ArcMountManager` (actor): mount/unmount/forget/rmdir через `CommandRunner`.
- `CommandRunner` (protocol + `ProcessCommandRunner`): запуск `Process`,
  построчный стриминг stdout/stderr в лог через `AsyncStream`.
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
