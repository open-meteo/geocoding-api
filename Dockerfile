# ================================
# Build image
# ================================
FROM swift:6.2.4-jammy AS build
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package resolve

# Compile dependencies before application sources enter the cache key.
RUN mkdir -p Sources/App/ProtoResources Sources/Run Sources/PrepareDatabase Tests/AppTests \
    && touch Sources/App/placeholder.swift Sources/Run/main.swift Sources/PrepareDatabase/main.swift Tests/AppTests/placeholder.swift
RUN swift build -c release --product Run \
    && swift build -c release --product PrepareDatabase
RUN rm -rf Sources

# Copy only files needed for application compilation.
COPY Sources ./Sources

# Compile and link the application against the cached dependencies.
RUN swift build -c release --product Run \
    && swift build -c release --product PrepareDatabase

# ================================
# Run image
# ================================
FROM swift:6.2.4-jammy-slim AS runtime-base

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy the executables
COPY --from=build --chown=vapor:vapor /build/.build/release/Run /app/Run
COPY --from=build --chown=vapor:vapor /build/.build/release/PrepareDatabase /app/PrepareDatabase

# ================================
# Data initialization image
# ================================
FROM runtime-base AS data-init

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip util-linux \
    && rm -rf /var/lib/apt/lists/*
COPY docker/prepare-data.sh /usr/local/bin/prepare-data

ENTRYPOINT ["/usr/local/bin/prepare-data"]

# ================================
# API runtime image
# ================================
FROM runtime-base AS runtime

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Start the Vapor service when the image is run, default to listening on 8080 in production environment 
ENTRYPOINT ["./Run"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
