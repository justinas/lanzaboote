{ pkgs
, lanzabooteModule
}:

let
  inherit (pkgs) lib;

  mkSecureBootTest = { name, machine ? { }, useSecureBoot ? true, testScript }: pkgs.nixosTest {
    inherit name testScript;
    nodes.machine = { lib, ... }: {
      imports = [
        lanzabooteModule
        machine
      ];

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;

        inherit useSecureBoot;
      };

      boot.loader.efi = {
        canTouchEfiVariables = true;
      };
      boot.lanzaboote = {
        enable = true;
        enrollKeys = lib.mkDefault true;
        pkiBundle = ./fixtures/uefi-keys;
      };
    };
  };

  # Execute a boot test that has an intentionally broken secure boot
  # chain. This test is expected to fail with Secure Boot and should
  # succeed without.
  #
  # Takes a set `path` consisting of a `src` and a `dst` attribute. The file at
  # `src` is copied to `dst` inside th VM. Optionally append some random data
  # ("crap") to the end of the file at `dst`. This is useful to easily change
  # the hash of a file and produce a hash mismatch when booting the stub.
  mkHashMismatchTest = { name, path, appendCrap ? false, useSecureBoot ? true }: mkSecureBootTest {
    inherit name;
    inherit useSecureBoot;

    testScript = ''
      import json
      import os.path
      bootspec = None

      def convert_to_esp(store_file_path):
          store_dir = os.path.basename(os.path.dirname(store_file_path))
          filename = os.path.basename(store_file_path)
          return f'/boot/EFI/nixos/{store_dir}-{filename}.efi'

      machine.start()
      bootspec = json.loads(machine.succeed("cat /run/current-system/boot.json")).get('org.nixos.bootspec.v1')
      assert bootspec is not None, "Unsupported bootspec version!"
      src_path = ${path.src}
      dst_path = ${path.dst}
      machine.succeed(f"cp -rf {src_path} {dst_path}")
    '' + lib.optionalString appendCrap ''
      machine.succeed(f"echo Foo >> {dst_path}")
    '' +
    ''
      machine.succeed("sync")
      machine.crash()
      machine.start()
    '' + (if useSecureBoot then ''
      machine.wait_for_console_text("Hash mismatch")
    '' else ''
      # Just check that the system came up.
      print(machine.succeed("bootctl", timeout=120))
    '');
  };

  # The initrd is not directly signed. Its hash is embedded into
  # lanzaboote. To make integrity verification fail, we actually have
  # to modify the initrd. Appending crap to the end is a harmless way
  # that would make the kernel still accept it.
  mkModifiedInitrdTest = { name, useSecureBoot }: mkHashMismatchTest {
    inherit name useSecureBoot;

    path = {
      src = "bootspec.get('initrd')";
      dst = "convert_to_esp(bootspec.get('initrd'))";
    };

    appendCrap = true;
  };

  mkModifiedKernelTest = { name, useSecureBoot }: mkHashMismatchTest {
    inherit name useSecureBoot;

    path = {
      src = "bootspec.get('kernel')";
      dst = "convert_to_esp(bootspec.get('kernel'))";
    };

    appendCrap = true;
  };

in
{
  # TODO: user mode: OK
  # TODO: how to get in: {deployed, audited} mode ?
  basic = mkSecureBootTest {
    name = "lanzaboote";
    testScript = ''
      machine.start()
      assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
    '';
  };

  systemd-initrd = mkSecureBootTest {
    name = "lanzaboote-systemd-initrd";
    machine = { ... }: {
      boot.initrd.systemd.enable = true;
    };
    testScript = ''
      machine.start()
      assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
    '';
  };

  # Test that a secret is appended to the initrd during installation. Smilar to
  # the initrd-secrets test in Nixpkgs:
  # https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/initrd-secrets.nix
  initrd-secrets =
    let
      secret = (pkgs.writeText "oh-so-secure" "uhh-ooh-uhh-security");
    in
    mkSecureBootTest {
      name = "lanzaboote-initrd-secrets";
      machine = { ... }: {
        boot.initrd.secrets = {
          "/test" = secret;
        };
        boot.initrd.postMountCommands = ''
          cp /test /mnt-root/secret-from-initramfs
        '';
      };
      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        machine.succeed("cmp ${secret} /secret-from-initramfs")
        assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
      '';
    };

  # Test that the secrets configured to be appended to the initrd get updated
  # when installing a new generation even if the initrd itself (i.e. its store
  # path) does not change. 
  #
  # An unfortunate result of this NixOS feature is that updating the secrets
  # without creating a new initrd might break previous generations. Lanzaboote
  # has no control over that.
  #
  # This tests uses a specialisation to imitate a newer generation. This works
  # because `lzbt` installs the specialisation of a generation AFTER installing
  # the generation itself (thus making the specialisation "newer").
  initrd-secrets-update =
    let
      originalSecret = (pkgs.writeText "oh-so-secure" "uhh-ooh-uhh-security");
      newSecret = (pkgs.writeText "newly-secure" "so-much-better-now");
    in
    mkSecureBootTest {
      name = "lanzaboote-initrd-secrets-update";
      machine = { pkgs, lib, ... }: {
        boot.initrd.secrets = {
          "/test" = lib.mkDefault originalSecret;
        };
        boot.initrd.postMountCommands = ''
          cp /test /mnt-root/secret-from-initramfs
        '';

        specialisation.variant.configuration = {
          boot.initrd.secrets = {
            "/test" = newSecret;
          };
        };
      };
      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        # Assert that only two boot files exists (a single kernel and a single
        # initrd). If there are two initrds, the test would not be able to test
        # updating the secret of an already existing initrd.
        assert int(machine.succeed("ls -1 /boot/EFI/nixos | wc -l")) == 2

        # It is expected that the initrd contains the new secret.
        machine.succeed("cmp ${newSecret} /secret-from-initramfs")
      '';
    };

  modified-initrd-doesnt-boot-with-secure-boot = mkModifiedInitrdTest {
    name = "modified-initrd-doesnt-boot-with-secure-boot";
    useSecureBoot = true;
  };

  modified-initrd-boots-without-secure-boot = mkModifiedInitrdTest {
    name = "modified-initrd-boots-without-secure-boot";
    useSecureBoot = false;
  };

  modified-kernel-doesnt-boot-with-secure-boot = mkModifiedKernelTest {
    name = "modified-kernel-doesnt-boot-with-secure-boot";
    useSecureBoot = true;
  };

  modified-kernel-boots-without-secure-boot = mkModifiedKernelTest {
    name = "modified-kernel-boots-without-secure-boot";
    useSecureBoot = false;
  };

  specialisation-works = mkSecureBootTest {
    name = "specialisation-still-boot-under-secureboot";
    machine = { pkgs, ... }: {
      specialisation.variant.configuration = {
        environment.systemPackages = [
          pkgs.efibootmgr
        ];
      };
    };
    testScript = ''
      machine.start()
      print(machine.succeed("ls -lah /boot/EFI/Linux"))
      # TODO: make it more reliable to find this filename, i.e. read it from somewhere?
      machine.succeed("bootctl set-default nixos-generation-1-specialisation-variant.efi")
      machine.succeed("sync")
      machine.fail("efibootmgr")
      machine.crash()
      machine.start()
      print(machine.succeed("bootctl"))
      # Only the specialisation contains the efibootmgr binary.
      machine.succeed("efibootmgr")
    '';
  };

  # We test if we can install Lanzaboote without Bootspec support.
  synthesis = mkSecureBootTest {
    name = "lanzaboote-synthesis";
    machine = { lib, ... }: {
      boot.bootspec.enable = lib.mkForce false;
    };
    testScript = ''
      machine.start()
      assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
    '';
  };

  systemd-boot-loader-config = mkSecureBootTest {
    name = "lanzaboote-systemd-boot-loader-config";
    machine = {
      boot.loader.timeout = 0;
      boot.loader.systemd-boot.consoleMode = "auto";
    };
    testScript = ''
      machine.start()

      actual_loader_config = machine.succeed("cat /boot/loader/loader.conf").split("\n")
      expected_loader_config = ["timeout 0", "console-mode auto"]
      
      assert all(cfg in actual_loader_config for cfg in expected_loader_config), \
        f"Expected: {expected_loader_config} is not included in actual config: '{actual_loader_config}'"
    '';
  };

  export-efi-variables = mkSecureBootTest {
    name = "lanzaboote-exports-efi-variables";
    testScript = ''
      import struct

      machine.start()
      SD_LOADER_GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
      expected_variables = ["LoaderDevicePartUUID",
        "LoaderImageIdentifier",
        "LoaderFirmwareInfo",
        "LoaderFirmwareType",
        "StubInfo",
        "StubFeatures"
      ]

      def read_raw_variable(var: str) -> bytes:
          attr_var = machine.succeed(f"cat /sys/firmware/efi/efivars/{var}-{SD_LOADER_GUID}").encode('raw_unicode_escape')
          _ = attr_var[:4] # First 4 bytes are attributes according to https://www.kernel.org/doc/html/latest/filesystems/efivarfs.html
          value = attr_var[4:]
          return value
      def read_string_variable(var: str, encoding='utf-16-le') -> str:
          return read_raw_variable(var).decode(encoding).rstrip('\x00')
      def assert_variable_string(var: str, expected: str, encoding='utf-16-le'):
          with subtest(f"Is `{var}` correctly set"):
              value = read_string_variable(var, encoding)
              assert value == expected, f"Unexpected variable value in `{var}`, expected: `{expected.encode(encoding)!r}`, actual: `{value.encode(encoding)!r}`"
      def assert_variable_string_contains(var: str, expected_substring: str):
          with subtest(f"Do `{var}` contain expected substrings"):
              value = read_string_variable(var).strip()
              assert expected_substring in value, f"Did not find expected substring in `{var}`, expected substring: `{expected_substring}`, actual value: `{value}`"

      # Debug all systemd loader specification GUID EFI variables loaded by the current environment.
      print(machine.succeed(f"ls /sys/firmware/efi/efivars/*-{SD_LOADER_GUID}"))
      with subtest("Check if supported variables are exported"):
          for expected_var in expected_variables:
              machine.succeed(f"test -e /sys/firmware/efi/efivars/{expected_var}-{SD_LOADER_GUID}")

      with subtest("Is `StubInfo` correctly set"):
          assert "lanzastub" in read_string_variable("StubInfo", 'utf8'), "Unexpected stub information, provenance is not lanzaboote project!"

      assert_variable_string("LoaderImageIdentifier", "\\EFI\\BOOT\\BOOTX64.EFI")
      # TODO: exploit QEMU test infrastructure to pass the good value all the time.
      assert_variable_string("LoaderDevicePartUUID", "1c06f03b-704e-4657-b9cd-681a087a2fdc")
      # OVMF tests are using EDK II tree.
      assert_variable_string_contains("LoaderFirmwareInfo", "EDK II")
      assert_variable_string_contains("LoaderFirmwareType", "UEFI")

      with subtest("Is `StubFeatures` non-zero"):
          assert struct.unpack('<Q', read_raw_variable("StubFeatures")) != 0
    '';
  };
}
