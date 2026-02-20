# ⚓ Dockyard Legacy

PHP project setup tool with automatic port assignment, SSL certificates, local domain configuration, and **legacy PHP version support** (PHP 5.6 → 7.3).

Unlike Laravel Sail, Dockyard works for **any PHP project**: Laravel, CakePHP, or generic legacy projects.

## Features

- 🐘 **Legacy PHP support** — PHP 5.6, 7.0, 7.1, 7.2, 7.3
- 🍰 **Multi-framework** — Laravel, CakePHP, or generic PHP projects
- 🚢 **Automatic port assignment** — intelligent port allocation across all your projects
- 🔍 **Port conflict detection** — prevents conflicts with running services
- 🌐 **Local domain registration** — seamless integration with Herd or Valet
- 🔒 **SSL certificate management** — automatic SSL setup and symlinking
- 🧙 **Interactive setup wizard** — collects all input upfront, then runs unattended
- 📦 **Batteries included** — nginx, MySQL, Redis, Mailpit — all optional
- 🔄 **Self-updating** — built-in update mechanism via `--update`

## Requirements

- **OS**: macOS or Linux
- **Docker**: Docker Desktop (or OrbStack) installed and running
- **Optional**: Laravel Herd or Laravel Valet (for domain registration)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/dockyard/main/install.sh | bash
```

After installation, restart your terminal or run:

```bash
source ~/.zshrc  # or ~/.bashrc
```

### Manual installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/dockyard/main/dockyard.sh \
    -o ~/.local/bin/dockyard
chmod +x ~/.local/bin/dockyard
```

## Usage

Navigate to your project directory and run:

```bash
dockyard init
```

### What happens

The wizard will guide you through:

1. **PHP version** — auto-detected from `composer.json` or `.php-version`, then normalized and validated to legacy range
2. **Project type** — auto-detected (Laravel / CakePHP / generic), with override
3. **Document root** — auto-detected per project type (`public`, `webroot`, etc.)
4. **Services** — optional MySQL, Redis
5. **Domain registration** — optional `.test` domain via Herd/Valet
6. **Protocol** — HTTPS (with SSL symlinks) or HTTP
7. **Post-setup** — optionally build containers and run framework setup commands

### Commands

```bash
dockyard init      # Initialize project setup wizard
dockyard list      # Show all registered projects
dockyard info      # Show info for current project
dockyard cleanup   # Remove stale projects from registry
dockyard --version # Show version
dockyard --update  # Update to latest version
dockyard --help    # Show help
```

## How it works

### Auto-detection

Dockyard detects your project type and PHP version automatically:

| Signal | Detected as |
|---|---|
| `artisan` file present | Laravel |
| `bin/cake`, `"cakephp/cakephp"` in composer, or klassieke CakePHP2 mappen (`Config`, `Controller`, `Model`, `View`, `webroot`) | CakePHP |
| `composer.json` `require.php` constraint | PHP version |
| `.php-version` file | PHP version |

### Generated files

Running `dockyard init` generates the following in your project:

```
your-project/
├── .dockyard/
│   ├── config.yml      ← commit this (project config)
│   ├── Dockerfile      ← gitignored (generated per-run)
│   ├── nginx.conf      ← gitignored (generated per-run)
│   └── php.ini         ← gitignored (generated per-run)
├── docker-compose.yml  ← generated (or overwritten with consent)
├── certificates/
│   ├── cert.crt        ← symlink to Herd/Valet cert (or empty)
│   └── cert.key        ← symlink to Herd/Valet key (or empty)
└── .env                ← updated with ports and URLs
```

The `.dockyard/config.yml` is meant to be committed so teammates can regenerate the Docker setup by running `dockyard init`.

### PHP version support

Dockyard uses official Docker Hub `php:X.X-fpm` images combined with nginx, and targets legacy PHP projects only.

The Dockerfile is generated dynamically and handles differences in extension installation between PHP versions (e.g. `gd` configure flags changed between versions).

Supported range: **5.6 → 7.3**.

If a detected PHP version falls outside that range (for example `5.3` or `8.2`), Dockyard suggests the nearest supported legacy version in the wizard.

### Port assignment strategy

Dockyard converts standard ports to 4-digit variants and auto-increments if taken:

| Service | Base port |
|---|---|
| App (nginx) | 8000 |
| MySQL | 3300 |
| Redis | 6300 |
| Mailpit SMTP | 1025 |
| Mailpit Dashboard | 8025 |

Port availability is checked against both the global registry and live system ports (`/dev/tcp` + `lsof`).

### Domain registration (Herd/Valet)

If Herd or Valet is installed, Dockyard can:

1. Create a proxy: `myproject.test` → `http://localhost:8000`
2. Optionally enable HTTPS with a valid SSL certificate
3. Symlink certificates into `certificates/` for use with Vite dev server

### Registry

Dockyard maintains a global registry at `~/.config/dockyard/projects.conf`:

```ini
[my-project]
path=/path/to/project
php=7.3
type=cakephp
APP_PORT=8001
FORWARD_DB_PORT=3301
domain=my-project.test
proxy_service=herd
proxy_secure=true
```

## Updating

```bash
dockyard --update
```

## Uninstalling

```bash
rm ~/.local/bin/dockyard
rm -rf ~/.config/dockyard  # optional: removes registry
```

## Repository structure

```
dockyard/
├── README.md
├── CHANGELOG.md
├── LICENSE
├── dockyard.sh     ← main script
└── install.sh      ← installer
```

## Legacy defaults

- MySQL service uses `mysql:5.7` for better compatibility with older frameworks and drivers.
- If detected PHP version is not in the supported legacy range, Dockyard asks for a compatible version.

## License

MIT License

## Contributing

Issues and pull requests welcome!
