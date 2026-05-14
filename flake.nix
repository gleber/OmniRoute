{
  description = "OmniRoute — unified AI proxy/router, 160+ LLM providers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # NixOS module is system-independent, defined outside eachDefaultSystem
      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg = config.services.omniroute;
          pkg = cfg.package;
        in {
          options.services.omniroute = {
            enable = lib.mkEnableOption "OmniRoute AI proxy/router";

            package = lib.mkPackageOption pkgs "omniroute" {};

            dataDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/omniroute";
              description = "Directory for OmniRoute's SQLite database and persistent data (DATA_DIR).";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 20128;
              description = "TCP port the OmniRoute server listens on.";
            };

            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Host/address the server binds to. Set to 0.0.0.0 to expose on all interfaces.";
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Open the firewall for the OmniRoute port.";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "omniroute";
              description = "User account the OmniRoute service runs as.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "omniroute";
              description = "Group the OmniRoute service runs as.";
            };

            # Secret files are loaded via systemd's LoadCredential so they
            # never appear in the Nix store or world-readable /proc.
            jwtSecretFile = lib.mkOption {
              type = lib.types.path;
              description = ''
                Path to a file containing the JWT_SECRET value (used to sign
                session cookies). Generate with: openssl rand -base64 48
              '';
            };

            apiKeySecretFile = lib.mkOption {
              type = lib.types.path;
              description = ''
                Path to a file containing the API_KEY_SECRET value (used to
                encrypt API keys at rest). Generate with: openssl rand -hex 32
              '';
            };

            initialPasswordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Optional path to a file containing the INITIAL_PASSWORD for the
                first dashboard login. Once changed via the dashboard, this is
                no longer needed.
              '';
            };

            storageEncryptionKeyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Optional path to a file containing the STORAGE_ENCRYPTION_KEY
                (AES-256-GCM, 64 hex chars). When set, OmniRoute uses this key
                to encrypt/decrypt provider credentials instead of
                auto-generating one and writing it to $DATA_DIR/server.env.

                Providing this externally is the only way to survive container
                recreation (or accidental loss of $DATA_DIR/server.env)
                without losing every provider credential stored in SQLite —
                without the original key, those rows are permanently
                unreadable.

                Generate with: openssl rand -hex 32
              '';
            };

            extraEnvironment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              example = lib.literalExpression ''
                {
                  APP_LOG_LEVEL = "warn";
                  REQUIRE_API_KEY = "true";
                  # Default per-day request budget applied to API keys that
                  # have no per-key rate_limits configured. "0" (the default)
                  # disables the fallback limits entirely — keys without a
                  # configured limit are then unlimited. Any positive integer
                  # N enables N/day, 5N/week, 20N/month windows.
                  DEFAULT_RATE_LIMIT_PER_DAY = "0";
                }
              '';
              description = ''
                Extra environment variables passed to the OmniRoute process.

                Notable knobs:
                - DEFAULT_RATE_LIMIT_PER_DAY: fallback per-day request budget
                  for API keys whose `rate_limits` column is null. "0" means
                  unlimited (skip the default windows); any positive integer
                  N enables N/day + 5N/week + 20N/month limits.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            users.users.${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              home = cfg.dataDir;
              createHome = false;
              description = "OmniRoute service user";
            };

            users.groups.${cfg.group} = {};

            systemd.tmpfiles.rules = [
              "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
            ];

            systemd.services.omniroute =
              let
                # The OmniRoute app reads JWT_SECRET / API_KEY_SECRET /
                # INITIAL_PASSWORD directly from the environment — it does not
                # honor the _FILE convention. So a wrapper exports each value
                # from systemd's credentials directory (readable only by the
                # service user, mounted at $CREDENTIALS_DIRECTORY) into the
                # env immediately before exec'ing the server. Keeping the
                # secret-file path out of process env / argv means it never
                # appears in /proc/<pid>/environ or in journal logs.
                startScript = pkgs.writeShellScript "omniroute-start" ''
                  set -eu
                  JWT_SECRET="$(< "$CREDENTIALS_DIRECTORY/jwt_secret")"
                  API_KEY_SECRET="$(< "$CREDENTIALS_DIRECTORY/api_key_secret")"
                  export JWT_SECRET API_KEY_SECRET
                  if [ -e "$CREDENTIALS_DIRECTORY/initial_password" ]; then
                    INITIAL_PASSWORD="$(< "$CREDENTIALS_DIRECTORY/initial_password")"
                    export INITIAL_PASSWORD
                  fi
                  if [ -e "$CREDENTIALS_DIRECTORY/storage_encryption_key" ]; then
                    STORAGE_ENCRYPTION_KEY="$(< "$CREDENTIALS_DIRECTORY/storage_encryption_key")"
                    export STORAGE_ENCRYPTION_KEY
                  fi
                  exec ${pkg}/bin/omniroute
                '';
              in
              {
                description = "OmniRoute AI proxy/router";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];

                serviceConfig = {
                  Type = "simple";
                  User = cfg.user;
                  Group = cfg.group;

                  ExecStart = "${startScript}";

                  LoadCredential = lib.flatten [
                    "jwt_secret:${cfg.jwtSecretFile}"
                    "api_key_secret:${cfg.apiKeySecretFile}"
                    (lib.optional (cfg.initialPasswordFile != null)
                      "initial_password:${cfg.initialPasswordFile}")
                    (lib.optional (cfg.storageEncryptionKeyFile != null)
                      "storage_encryption_key:${cfg.storageEncryptionKeyFile}")
                  ];

                  # Security hardening
                  NoNewPrivileges = true;
                  PrivateTmp = true;
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  ReadWritePaths = [ cfg.dataDir ];
                  CapabilityBoundingSet = "";
                  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
                  RestrictNamespaces = true;
                  LockPersonality = true;
                  MemoryDenyWriteExecute = false; # JIT (V8) needs W^X off
                  RestrictRealtime = true;

                  Restart = "on-failure";
                  RestartSec = "5s";
                };

                environment = lib.mkMerge [
                  {
                    NODE_ENV = "production";
                    DATA_DIR = cfg.dataDir;
                    PORT = toString cfg.port;
                    HOSTNAME = cfg.host;
                    NEXT_TELEMETRY_DISABLED = "1";
                  }
                  cfg.extraEnvironment
                ];
              };

            networking.firewall.allowedTCPPorts =
              lib.optional cfg.openFirewall cfg.port;
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        omniroute = pkgs.buildNpmPackage {
          pname = "omniroute";
          version = "3.8.0";

          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter = path: type:
              let base = baseNameOf path; in
              # Exclude build artifacts, data dirs, and local tooling
              !(builtins.elem base [
                ".next" ".devenv" "node_modules" ".omniroute"
                ".git" "coverage" "dist" ".tmp"
              ]);
          };

          nodejs = pkgs.nodejs_22;

          npmDepsHash = "sha256-VnJySd425/z8YgquzyRr7G962y1lyAIfBldgcm6zdwo=";

          # NODE_ENV=production in the build env causes `npm ci` to skip
          # devDependencies — but the Next build needs `@tailwindcss/postcss`
          # and other build-time tools from devDeps. Force include.
          npmInstallFlags = [ "--include=dev" ];

          nativeBuildInputs = with pkgs; [
            python3          # node-gyp (better-sqlite3)
            pkg-config
            makeWrapper
            autoPatchelfHook # fixes pre-built NAPI binaries (wreq-js)
          ];

          buildInputs = with pkgs; [
            # better-sqlite3 links against libstdc++ at runtime
            stdenv.cc.cc.lib
            # keytar native build needs libsecret (libsecret-1.pc)
            libsecret
          ];

          # Many native deps ship binaries for *every* platform — including
          # musl, OpenBSD, etc. — that we don't use on glibc Linux. Tell
          # autoPatchelfHook to ignore unresolved deps in those alt-platform
          # binaries instead of failing the build.
          autoPatchelfIgnoreMissingDeps = [
            "libc.musl-x86_64.so.1"
            "libc++.so.9.0"
            "libc++abi.so.6.0"
            "libpthread.so.26.1"
            "libm.so.10.1"
          ];

          env = {
            NODE_ENV = "production";
            NEXT_TELEMETRY_DISABLED = "1";
            # Prevent Next.js from trying to reach CDN during build
            NEXT_PRIVATE_STANDALONE = "1";
            # Use Turbopack (matches devenv config); webpack 16 has issues with
            # directory imports for some `@/...` paths in this codebase.
            OMNIROUTE_USE_TURBOPACK = "1";
          };

          # No source-level patches needed at this base — the four fixes
          # that used to live in nix/patches/ are all now upstream:
          # - static-cli-helper imports (release/v3.8.0 ships static imports)
          # - PR diegosouzapw/OmniRoute#2264 (Content-Length strip)
          # - PR diegosouzapw/OmniRoute#2265 (manage-scope auth)
          # - PR diegosouzapw/OmniRoute#2266 (configurable default rate limits)

          # Three offline-build stubs:
          #
          # 1. next/font/google fetches font CSS over the network at build
          #    time — the Nix sandbox has no network, so we stub the import.
          #    The <link> tag in layout.tsx still loads webfonts at runtime.
          #
          # 2. TierFlowDiagram imports `next-themes`, which is referenced in
          #    source on release/v3.8.0 but missing from package.json there
          #    (upstream bug). Stub `useTheme()` to always return dark mode
          #    so Next's outputFileTracing succeeds.
          #
          # 3. bin/cli/runtime/sqliteRuntime.mjs has a 5-step fallback chain
          #    whose last two steps `await import("sql.js")` and
          #    `await import(pkgRoot)` (a variable path). Neither resolves
          #    in the build sandbox (sql.js not in deps, pkgRoot is dynamic).
          #    The server build does not need that fallback — better-sqlite3
          #    is in the bundle — so replace the file with a minimal stub
          #    that just loads better-sqlite3 directly.
          postPatch = ''
            substituteInPlace src/app/layout.tsx \
              --replace-fail 'import { Inter } from "next/font/google";' \
                            'const Inter = () => ({ className: "", variable: "--font-inter", style: {} });'

            substituteInPlace 'src/app/(dashboard)/dashboard/onboarding/components/TierFlowDiagram.tsx' \
              --replace-fail 'import { useTheme } from "next-themes";' \
                            'const useTheme = () => ({ resolvedTheme: "dark" });'

            cat > bin/cli/runtime/sqliteRuntime.mjs <<'STUB'
            // Stubbed by Nix flake — the upstream fallback chain references
            // `sql.js` (not in package.json) and a dynamic `import(pkgRoot)`,
            // both of which fail Next.js outputFileTracing. The bundled
            // better-sqlite3 covers every server path that touches sqlite,
            // so the chain is dead code in this build.
            let resolvedCached = null;
            export async function loadSqliteRuntime() {
              if (resolvedCached) return resolvedCached;
              const mod = await import("better-sqlite3");
              resolvedCached = {
                driver: { kind: "better-sqlite3", Database: mod.default ?? mod },
                source: "bundled",
              };
              return resolvedCached;
            }
            export function clearRuntimeCache() { resolvedCached = null; }
            STUB
          '';

          # The custom build script temporarily shelves legacy dirs before
          # calling `next build`.  In the Nix sandbox those dirs don't exist
          # so the script is safe to call directly.
          buildPhase = ''
            runHook preBuild
            npm run build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            local standalone=".next/standalone"

            # Copy the Next.js standalone server tree
            mkdir -p "$out/lib/omniroute"
            cp -r "$standalone/." "$out/lib/omniroute/"

            # Next.js standalone does NOT include browser assets — add them
            cp -r ".next/static" "$out/lib/omniroute/.next/static"

            # public/ must sit next to server.js for Next.js to serve it
            if [ -d public ]; then
              cp -r public "$out/lib/omniroute/public"
            fi

            # Wrap server.js as a proper executable
            mkdir -p "$out/bin"
            makeWrapper "${pkgs.nodejs_22}/bin/node" "$out/bin/omniroute" \
              --add-flags "$out/lib/omniroute/server.js"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Unified AI proxy/router — one endpoint, 160+ LLM providers";
            homepage = "https://github.com/diegosouzapw/OmniRoute";
            license = licenses.mit;
            mainProgram = "omniroute";
            platforms = platforms.linux ++ platforms.darwin;
          };
        };
      in {
        packages = {
          inherit omniroute;
          default = omniroute;
        };

        # Quick smoke-test: the built binary must accept --version or start
        checks = {
          package = omniroute;
        } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # NixOS VM test: boots the module, starts the service, confirms
          # the server answers on the configured port. Linux-only because
          # nixosTest needs a real qemu VM.
          module = import ./nix/tests/module.nix {
            inherit pkgs;
            module = nixosModule;
            package = omniroute;
          };
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ omniroute ];
          packages = [ pkgs.nodejs_22 ];
        };
      }
    ) // {
      nixosModules = {
        omniroute = nixosModule;
        default = nixosModule;
      };
    };
}
