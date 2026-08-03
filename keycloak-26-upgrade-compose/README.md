# Upgrade Keycloak 20.0.5 to Keycloak 26.7.0

This project upgrades the previous ZIP-based Keycloak 20.0.5 Docker Compose
setup to Keycloak 26.7.0 while keeping the existing PostgreSQL 15 database.

## Very important rules

1. Back up PostgreSQL before starting Keycloak 26.
2. Never run `docker compose down --volumes` during the upgrade.
3. Run the replacement files from the same Compose project directory as the
   Keycloak 20 files so the existing `keycloak_postgres_data` volume is reused.
4. Keep the old Keycloak 20 files and the database backup until testing is done.
5. Rolling directly from Keycloak 20 to 26 is not a zero-downtime upgrade.

## What changes

- Keycloak: 20.0.5 -> 26.7.0
- Java runtime: Java 17 -> Java 21
- Admin variables:
  - `KEYCLOAK_ADMIN` -> `KC_BOOTSTRAP_ADMIN_USERNAME`
  - `KEYCLOAK_ADMIN_PASSWORD` -> `KC_BOOTSTRAP_ADMIN_PASSWORD`
- Health URL:
  - old lab check: `http://localhost:8080/health/ready`
  - Keycloak 26 check: `http://localhost:9000/health/ready`
- Keycloak 26 persists user sessions in PostgreSQL by default.

The bootstrap admin variables do not reset an existing administrator's
password. They are used only when an initial administrator must be created.

## Recommended in-place upgrade

### 1. Save the old files

From the original Keycloak 20 project directory:

```bash
mkdir -p pre-upgrade-keycloak20
cp Dockerfile docker-compose.yml README.md pre-upgrade-keycloak20/
```

### 2. Copy the new files into the original directory

Replace the old `Dockerfile` and `docker-compose.yml` with the files from this
project. Also copy `.env.example` and the `scripts` directory.

```bash
cp .env.example .env
```

Edit `.env` so the PostgreSQL database name, user, and password exactly match
the Keycloak 20 setup.

### 3. Confirm the existing Docker volume

```bash
docker volume ls | grep keycloak_postgres_data
```

Do not continue if the volume is missing. Starting from a different directory
can cause Compose to create a new empty volume.

### 4. Back up and upgrade

```bash
./scripts/upgrade-to-26.sh
```

The script:

1. Starts PostgreSQL if needed.
2. Creates a custom-format `pg_dump` file under `backups/`.
3. Stops Keycloak without deleting PostgreSQL.
4. Builds Keycloak 26.7.0 from the official ZIP distribution.
5. Starts Keycloak and lets Keycloak migrate the database schema.

### 5. Watch the database migration

```bash
docker compose logs -f keycloak
```

Wait for a successful startup. Do not interrupt the first startup while the
database migration is running.

### 6. Check health

```bash
curl http://localhost:9000/health/ready
```

Expected result includes:

```json
{"status":"UP"}
```

### 7. Check the Keycloak schema version

```bash
./scripts/show-database-version.sh
```

### 8. Test the application

Test at least these items:

- Existing administrator login
- Every realm
- Existing users, groups, roles, and clients
- Normal user login
- Token refresh
- Logout
- Password reset email
- LDAP or Active Directory federation
- External identity providers
- Custom themes
- Custom providers and event listeners
- Applications using Keycloak adapters or client libraries

OIDC discovery test:

```bash
curl http://localhost:8080/realms/master/.well-known/openid-configuration
```

## Direct upgrade versus Keycloak 25 first

For this single-node development Compose setup, stopping Keycloak 20 already
removes its in-memory online sessions. A direct database upgrade to 26 is
reasonable when users logging in again is acceptable.

For environments where online sessions are stored externally and must survive,
review the Keycloak 25 persistent-user-session migration before moving to 26.
Keycloak 26 changed cache marshalling and clears incompatible caches during the
upgrade.

## Common compatibility checks

### Custom providers

Keycloak 22 moved to Quarkus 3 and Jakarta EE. Rebuild custom provider JAR files
against the Keycloak 26 APIs. Code importing `javax.*` APIs may need to use
`jakarta.*` APIs.

For an optimized production image, copy provider JARs into
`/opt/keycloak/providers` before running `kc.sh build`.

### Themes

Account Console v2 was removed in Keycloak 25. Keycloak 26 also has a newer
login theme. Test custom login, account, admin, and email themes carefully.

### Hostname and proxy settings

Keycloak 25 introduced the newer hostname configuration. Review old settings
such as `KC_PROXY`, `KC_HOSTNAME_URL`, and `KC_HOSTNAME_ADMIN_URL` before using
this configuration behind a reverse proxy.

### Application adapters

Most old Java servlet, Spring, Tomcat, WildFly, and similar adapters were
removed from Keycloak downloads. Applications should normally use their
framework's OAuth 2.0 or OpenID Connect support.

## Development command

This project uses:

```bash
kc.sh start-dev
```

Do not add `--optimized` to `start-dev`.

## Production command

The Dockerfile already runs `kc.sh build`. A production container can use:

```yaml
command:
  - start
  - --optimized
```

Production also requires a real hostname, HTTPS or a trusted TLS-terminating
reverse proxy, secure secrets, network restrictions, backups, and tested
rollback procedures.

## Rollback

The upgraded database schema is not safe for the old Keycloak 20 server. To
roll back:

1. Stop Keycloak 26.
2. Restore the pre-upgrade PostgreSQL backup.
3. Restore the old Keycloak 20 Dockerfile and Compose file.
4. Rebuild and start Keycloak 20.

Example destructive restore command:

```bash
CONFIRM_RESTORE=YES ./scripts/restore-database.sh \
  backups/keycloak-before-upgrade-YYYYMMDD-HHMMSS.dump
```

Then restore the Keycloak 20 files and run:

```bash
docker compose build --no-cache keycloak
docker compose up -d
```

## Never use these commands until the upgrade is accepted

```bash
docker compose down --volumes
docker volume rm <the-keycloak-database-volume>
```

Those commands can delete the PostgreSQL data.
