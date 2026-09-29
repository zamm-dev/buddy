# Development

## Setup

```bash
git clone https://github.com/zamm-dev/buddy.git
cd buddy
flutter pub get
pre-commit install && pre-commit install --hook-type post-commit
```

## Commands

| Task | Command |
| --- | --- |
| Run the app | `flutter run -d chrome` |
| Run tests | `flutter test` |
| Format | `dart format .` |
| Analyze | `flutter analyze` |
| All hooks | `pre-commit run --all-files` |

## Documentation

The docs live in `docs/` and use Material for MkDocs with [uv](https://docs.astral.sh/uv/):

```bash
cd docs
uv run mkdocs serve
uv run mkdocs build --strict
```
