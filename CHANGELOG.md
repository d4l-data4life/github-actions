# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Generic secret slots `secret-1` … `secret-5`: pass up to five `${{ secrets.* }}` values via `with:` and reference them with `from-input: secret-N` in the `secrets` YAML. GitHub masks inputs sourced from secrets; `env:` on the calling step is logged in plaintext.

### Changed

- Preset secrets: use `from-input: secret-N` + `with: secret-N: ${{ secrets.* }}` instead of `from-env` + `env:` on the calling step

### Deprecated

- `from-env` combined with `env:` on the calling `uses:` step (leaks value in composite sub-step logs); use `from-input` with a generic slot instead

### Removed

### Fixed

### Security

- Prevent preset secret values from appearing in workflow logs when callers previously used `env:` on the composite action step

## [v1.4.0] - 2026-05-01

### Added

- Add seed-secrets action

## [v1.3.0] - 2026-03-29

### Added

- add support for local clusters via kubeconfig

## [v1.2.0] - 2026-03-21

### Added

- add support for public app tiers

## [v1.1.0] - 2026-03-18

### Added

- build-setup: allow to specify a custom docker cache registry
- DOCKER_CACHE_CONFIG environment variable is set to be used with `docker buildx build ${DOCKER_CACHE_CONFIG}`

## [v1.0.3] - 2025-12-10

### Fixed

- `REGISTRY` variable wasn't set in deploy workflow
- downgrade to setup-node@v4 to not depend on node24

## [v1.0.2] - 2025-07-15

### Fixed

- Moved `backend_cert_name` from airms project-wide scope to airms sandbox, as it's only defined there yet

## [v1.0.1] - 2025-07-15

### Fixed

- fix Key Vault address for airms prod

## [v0.1.0] - 2025-06-29

[Unreleased]: https://github.com/d4l-data4life/github-actions/compare/v1.4.0...HEAD
[v1.4.0]: https://github.com/d4l-data4life/github-actions/compare/v1.3.0...v1.4.0
[v1.3.0]: https://github.com/d4l-data4life/github-actions/compare/v1.2.0...v1.3.0
[v1.2.0]: https://github.com/d4l-data4life/github-actions/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/d4l-data4life/github-actions/compare/v1.0.3...v1.1.0
[v1.0.3]: https://github.com/d4l-data4life/github-actions/compare/v1.0.2...v1.0.3
[v1.0.2]: https://github.com/d4l-data4life/github-actions/compare/v1.0.1...v1.0.2
[v1.0.1]: https://github.com/d4l-data4life/github-actions/compare/v0.1.0...v1.0.1
[v0.1.0]: https://github.com/d4l-data4life/github-actions/releases/tag/v0.1.0
