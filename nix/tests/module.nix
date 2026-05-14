{
  pkgs,
  module,
  package,
}:

pkgs.testers.nixosTest {
  name = "omniroute-module";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ module ];

      # These secrets exist only inside the test VM and are loaded into the
      # service via systemd's LoadCredential mechanism. Do not copy this
      # pattern to a real deployment — production secrets should be agenix /
      # sops-nix / systemd-creds encrypted, not plain files in the store.
      services.omniroute = {
        enable = true;
        package = package;
        host = "127.0.0.1";
        port = 20128;
        jwtSecretFile = pkgs.writeText "omniroute-test-jwt" "not-for-production-use-only-in-this-vm";
        apiKeySecretFile = pkgs.writeText "omniroute-test-apikey" "not-for-production-use-only-in-this-vm";
        # 64 hex chars (32 bytes) — valid AES-256-GCM key format.
        storageEncryptionKeyFile = pkgs.writeText "omniroute-test-storage-key"
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
      };
    };

  testScript = ''
    machine.wait_for_unit("omniroute.service")
    machine.wait_for_open_port(20128)
    # Any HTTP response (200/3xx/401) proves the Next.js server is up.
    machine.succeed("curl -fsS -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:20128/")
    # Confirm the data directory was created with the configured ownership.
    machine.succeed("test -d /var/lib/omniroute")
    machine.succeed("stat -c '%U:%G' /var/lib/omniroute | grep -x omniroute:omniroute")
    # The wrapper must export the configured JWT_SECRET from the credentials
    # dir — if it does not, the app auto-generates a fresh secret and logs
    # that, which would defeat the whole LoadCredential setup.
    machine.fail("journalctl -u omniroute.service | grep -q 'JWT_SECRET auto-generated'")
    machine.fail("journalctl -u omniroute.service | grep -q 'API_KEY_SECRET auto-generated'")
    # When a STORAGE_ENCRYPTION_KEY is supplied, the app must not write its
    # own to $DATA_DIR/server.env — that file is the failure mode the option
    # exists to avoid.
    machine.fail("test -f /var/lib/omniroute/server.env")
  '';
}
