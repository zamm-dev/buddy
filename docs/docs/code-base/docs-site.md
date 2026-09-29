# Documentation site

The site is built with Material for MkDocs. Python dependencies are managed with uv (`docs/pyproject.toml`, `docs/uv.lock`).

- Content: `docs/docs/`
- Configuration: `docs/mkdocs.yml`
- Validation: the `mkdocs-build` pre-commit hook runs `mkdocs build --strict` whenever files under `docs/` change.
