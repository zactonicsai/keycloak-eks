# Keycloak 26.7.0 built from the official ZIP distribution.
# Java 21 matches the runtime used by the official Keycloak container image.
FROM eclipse-temurin:21-jre-jammy

ARG KEYCLOAK_VERSION=26.7.0
ARG KEYCLOAK_ZIP_URL=https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.zip

# curl downloads Keycloak and is also used by the container health check.
# unzip extracts the official Keycloak release archive.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN curl --fail --location --retry 3 --retry-delay 2 \
      "${KEYCLOAK_ZIP_URL}" \
      --output keycloak.zip \
    && unzip keycloak.zip \
    && mv "keycloak-${KEYCLOAK_VERSION}" keycloak \
    && rm keycloak.zip \
    && chmod +x /opt/keycloak/bin/kc.sh

# These are build-time options. Keycloak prepares an optimized PostgreSQL build.
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build

WORKDIR /opt/keycloak

EXPOSE 8080 9000

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start-dev"]
