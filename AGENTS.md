# 一个使用Flutter编写的应用
# Repository Guidelines

## Project Structure & Module Organization
- `lib/` — Flutter/Dart source code (main app widgets and business logic).
- `test/` — Unit and widget tests.
- `assets/` — Images, fonts, and static assets referenced in `pubspec.yaml`.
- `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/` — platform folders for platform-specific code.
- `tools/` — developer utilities and scripts.
- `secrets/` — local config (do NOT commit secrets; this folder is private).

## Build, Test, and Development Commands
- `flutter pub get` — fetch packages.
- `flutter run` — run app on a connected device or emulator.
- `flutter build <platform>` — build release for a platform (e.g., `flutter build apk`).
- `flutter test` — run unit & widget tests.
- `flutter analyze` — static analysis using `analysis_options.yaml`.

## Coding Style & Naming Conventions
- Follow Dart & Flutter style: 2-space indentation, `lowerCamelCase` for variables and methods, `UpperCamelCase` for classes and enums.
- File names: `snake_case.dart` (e.g., `floating_clock.dart`).
- Widgets: prefer small, single-responsibility widgets; split large widgets into private helper widgets.
- Formatting: run `dart format .` before committing.

## Testing Guidelines
- Tests live in `test/` and mirror `lib/` structure (e.g., `lib/src/foo.dart` → `test/src/foo_test.dart`).
- Use Flutter `testWidgets` for widget tests and plain `test` for unit tests.
- Aim for meaningful assertions and avoid flaky timing-based waits.
- Run `flutter test` locally; CI runs tests on PRs.

## Commit & Pull Request Guidelines
- Commit messages: short subject (50 chars) + optional body. Use present tense (e.g., "Add clock face widget").
- PRs require: descriptive title, summary of changes, linked issue if any, and screenshot/GIF for UI changes.
- Keep PRs focused and size-limited; rebase or squash as requested by maintainers.

## Security & Configuration Tips
- Never commit secrets. Use local env or encrypted secrets via CI.
- `secrets/` is for local development only and should remain out of VCS.


## 若无特别说明：'应用'/'App' 均指的是Android APK，当前仅考虑Android平台。

## 使用简体中文与我交流
