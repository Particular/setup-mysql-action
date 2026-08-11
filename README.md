# setup-mysql-action

Starts a MySQL server in a Docker container for your test run and removes it when the job ends. The same container image runs on Linux and Windows runners; on Windows it runs inside WSL2, so no native MySQL installation is needed on either platform.

## Prerequisites

This action does not provision WSL or Docker itself. On Windows runners it requires [setup-wsl-action](https://github.com/Particular/setup-wsl-action) to run first in the same job. That action provisions WSL2 and Docker, keeps the instance alive, and exports the `WSL_DISTRIBUTION`, `WSL_IP`, and `WSL_TOOLS_MODULE_PATH` environment variables this action relies on. On Linux runners setup-wsl-action is a no-op but should still be included so the workflow is uniform.

If setup-wsl-action has not run, the action fails fast with a clear error.

## Usage

See [action.yml](action.yml)

```yaml
steps:
- name: Setup WSL
  uses: Particular/setup-wsl-action@v1
- name: Setup MySQL
  uses: Particular/setup-mysql-action@v1.0.0
  with:
    connection-string-name: MySQLConnectionString
- name: Run tests
  shell: pwsh
  run: |
    $connectionString = $Env:MySQLConnectionString
    # Use the connection string in tests...
```

`connection-string-name` is required. `database-name` and `username` default to `nservicebus` and `particular`, the values the NServiceBus test setup used, so switching an existing workflow is a drop-in change.

## Inputs

| Input | Required | Default | Description |
|---|:-:|:-:|---|
| `connection-string-name` | Yes | - | Name of the environment variable that receives the MySQL connection string. |
| `database-name` | No | `nservicebus` | Database created for the connection string. |
| `username` | No | `particular` | User created for the connection string. |
| `image-tag` | No | `8.4` | Tag of the MySQL image. |
| `init-script` | No | - | Path to an SQL script, or a comma-separated list of scripts, executed once the server is ready. |
| `registry-login-server` | No | `index.docker.io` | Container registry to log in to on Windows runners. |
| `registry-username` | No | - | Username for the registry login. Login happens only when both username and password are set. |
| `registry-password` | No | - | Password for the registry login. Login happens only when both username and password are set. |

## Connection string

The action creates a root account and a user for the connection string, both with generated passwords, and exports the connection string to the environment variable you name:

```text
Data Source=127.0.0.1;Initial Catalog=nservicebus;User ID=particular;Password=<password>;AllowUserVariables=True;AutoEnlist=false;ConnectionReset=true;Connect Timeout=60
```

- On Linux the host is `127.0.0.1`.
- On Windows the host is the WSL2 VM IP address exported by setup-wsl-action.

The keyword set is what the NServiceBus MySql transport expects, so the string can be passed straight to `MySqlConnection`.

## Init scripts

`init-script` takes one SQL file, or several separated by commas. A list runs in order:

```yaml
- name: Setup MySQL
  uses: Particular/setup-mysql-action@v1.0.0
  with:
    connection-string-name: MySQLConnectionString
    init-script: .github/workflows/scripts/01-create-schema.sql,.github/workflows/scripts/02-seed.sql
```

The scripts run as root once the server accepts connections, so they can create databases, users, and grants beyond the defaults. They execute with the mysql client inside the container, so nothing needs to be installed on the runner. The action normalizes line endings before piping a script in, so a Windows checkout does not corrupt the SQL.

## mysql CLI shim

The action puts a `mysql` shim on `PATH` that forwards to the client inside the container, so the same command works on both platforms:

```pwsh
mysql --user=<user> --password=<password> --database=<database> --execute="SELECT 1"
```

The shim has no credentials of its own. Pass the user and password of any account the server knows, and SQL can also be piped through stdin.

## Cleanup

The action runs `dist/index.mjs` for both `main` and `post`. The post step removes the container it started. On hosted runners this is harmless, since the runner VM is destroyed at the end of the job, but it keeps long-lived self-hosted runners from accumulating orphaned containers.

## Local development

Install dependencies and build the bundle:

```bash
npm install
npm run prepare
```

The `prepare` script runs `@vercel/ncc` to bundle `index.mjs` and its dependencies into `dist/index.mjs`. The committed `dist/` is what the runner executes; the source `index.mjs` is not used directly.

To test `setup.ps1` directly:

```bash
$Env:RUNNER_OS=Linux
.\setup.ps1 -ContainerName setup-mysql-local -ConnectionStringName MySQLConnectionString
```

Open the folder in Visual Studio Code with the DevContainer for a consistent development environment with Node.js, Docker-in-Docker, and PowerShell.

## License

The scripts and documentation in this project are released under the [MIT License](LICENSE).
