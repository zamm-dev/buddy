# Deployment

## Documentation site

The docs are deployed to <https://zamm-dev.github.io/buddy/> by the `Build and Deploy Docs` workflow (`.github/workflows/build-docs.yml`), which builds the MkDocs site with uv and publishes it via GitHub Pages on every push to `main`.

GitHub Pages is configured in Settings → Pages with Source set to "GitHub Actions".

To deploy manually (for example to test documentation changes), run the workflow from the Actions tab or:

```bash
gh workflow run build-docs.yml
```

## Continuous integration

`.github/workflows/ci.yml` runs pre-commit checks and `flutter test` on every pull request and push to `main`. Both jobs (`pre-commit`, `test`) are required by branch protection.
