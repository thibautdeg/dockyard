# Changelog

All notable changes to Dockyard will be documented in this file.

## [0.1.6] - 2026-02-23

### Fixed
- PHP 5.6 images now use Composer 1 to support legacy lockfiles/packages that require `composer-plugin-api ^1.0`
- Post-setup Composer step now runs `composer install --no-dev` by default to avoid legacy dev-dependency incompatibilities

## [0.1.5] - 2026-02-23

### Added
- Optional post-start `composer install` step in `dockyard init` (runs inside the PHP container)
- CakePHP legacy core presence check with explicit warning when `Vendor/cakephp/cakephp/lib/Cake/bootstrap.php` is missing

## [0.1.4] - 2026-02-23

### Fixed
- Improved EOL Debian archive handling for legacy PHP images (5.6 → 7.3) by removing `*-updates` sources and forcing archive-compatible apt settings
- Added apt archive policy (`Check-Valid-Until=false` + insecure archive allowances) to prevent signature/metadata failures on old Debian mirrors
- Updated legacy extension install steps to use `apt-get ... --allow-unauthenticated` so PHP 5.6/7.x builds complete reliably on archived repositories

## [0.1.3] - 2026-02-20

### Fixed
- Buster and Stretch apt security URL became `archive.debian.org/debian-security/debian-security` (double path) — sed pattern now matches the full `security.debian.org/debian-security` hostname+path
- `--with-freetype`/`--with-jpeg` gd flags are only valid from PHP 7.4+ — PHP 7.2 and 7.3 now correctly use `--with-freetype-dir`/`--with-jpeg-dir`

## [0.1.2] - 2026-02-20

### Fixed
- `mysql:5.7` has no ARM64 image — added `platform: linux/amd64` to the MySQL service for Apple Silicon compatibility (runs via Rosetta)

## [0.1.1] - 2026-02-20

### Fixed
- `prompt_select` question and options were invisible when captured via `$()` — display output now goes to stderr

## [0.1.0] - 2026-02-20

### Added
- Initial release
- Interactive setup wizard (`dockyard init`)
- Auto-detection of PHP version from `composer.json` and `.php-version`
- Auto-detection of project type (Laravel, CakePHP, generic)
- Auto-detection of document root per project type
- Dynamic Dockerfile generation for PHP 5.6 → 8.4
- Dynamic nginx configuration per project type
- Dynamic `docker-compose.yml` generation with optional MySQL, Redis, Mailpit
- Automatic port assignment with conflict detection
- Global project registry at `~/.config/dockyard/projects.conf`
- Herd/Valet proxy integration with optional HTTPS/SSL
- SSL certificate symlinking from Herd/Valet
- `.env` auto-configuration
- `.gitignore` auto-update
- `dockyard list` command
- `dockyard info` command
- `dockyard cleanup` command for stale projects
- `--update` flag for self-updating
- Legacy PHP scope: 5.6 → 7.3
- PHP version normalization (`major.minor`) and strict legacy validation in setup wizard
- Automatic nearest-legacy PHP fallback suggestion when detected version is unsupported
- Improved CakePHP detection for classic CakePHP2 project structure
- MySQL 5.7 default for improved legacy compatibility
- Updated README with legacy-focused docs
