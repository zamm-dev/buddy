# buddy

A Flutter app.

## Setup

Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) (on macOS: `brew install --cask flutter`), then fetch dependencies:

```bash
flutter pub get
```

## Run

```bash
flutter run -d chrome
```

This launches the starter counter app ("Flutter Demo Home Page") in Chrome. Use `flutter devices` to see other targets (macOS, iOS simulator, Android emulator).

## Test

```bash
flutter test
```

Expected output ends with `All tests passed!`.

## Pre-commit hooks

Commits run these checks via [pre-commit](https://pre-commit.com):

- `dart format` — formatting
- `flutter analyze` — linting / static analysis
- `mkdocs build --strict` — documentation build validation (when `docs/` changes)

Tests run in CI, not in the hooks.

Setup for new contributors:

```bash
pre-commit install && pre-commit install --hook-type post-commit
```

Run manually:

```bash
pre-commit run --all-files
```

## Documentation

Project documentation lives in the `docs/` directory (Material for MkDocs, managed with [uv](https://docs.astral.sh/uv/)).

To run the documentation site locally:

```bash
cd docs
uv run mkdocs serve
```
