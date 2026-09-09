# XcodeCleaner

macOS-утилита для очистки Xcode, симуляторов и маунтов Arcadia.

## Сборка

    ./build.sh

Собирает release-бинарь через SwiftPM, упаковывает в `XcodeCleaner.app`
и копирует на рабочий стол. Xcode-проект не нужен.

Иконка приложения генерируется скриптом `Assets/make-icon.swift`
(`swift Assets/make-icon.swift`) в `Assets/AppIcon.png`; `build.sh`
подхватывает её автоматически, если файл присутствует.

## Тесты

    swift test

## Что чистит

См. `docs/superpowers/specs/2026-09-09-xcode-cleaner-design.md`.
Лог каждого прогона: `~/Desktop/Xcode Cleanup Logs/`.
