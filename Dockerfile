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

# Copy entire repo into container
COPY . .

# Compile with optimizations
RUN swift build -c release --product Run

# ================================
# Run image
# ================================
FROM swift:6.2.4-jammy-slim

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy the executable
COPY --from=build --chown=vapor:vapor /build/.build/release/Run /app/Run

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Start the Vapor service when the image is run, default to listening on 8080 in production environment 
ENTRYPOINT ["./Run"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
