# Legal notes

This is an independent hobby and research project. **It is not legal advice**, and nothing here
guarantees protection from any claim. If you have a legal concern about this repository, open an
issue or contact the maintainers and the material in question will be reviewed and, where
appropriate, removed promptly.

## Not affiliated with Apple, Samsung or anyone else

"Apple", "iOS", "iPhone", "XNU", "Darwin", "Metal", "CoreAnimation", "Samsung", "Galaxy",
"Exynos", "ARM", "Mali", "Qualcomm" and other names are trademarks of their owners. They are used
only to say which hardware and software this code works with. This project is not affiliated
with, endorsed by or sponsored by any of them.

## What is in this repository, and what is not

- **No Apple binaries.** The repository contains no iOS or macOS system files, no dyld shared
  cache, no firmware images, no IPSW or DMG contents, no trust caches and no decryption keys.
  To run this you supply the iOS userland yourself, from an IPSW you obtained from Apple, for a
  device you are entitled to use it on. The tools here only repackage what you give them.
- **No Samsung or other vendor firmware.** Device images, partition dumps and boot images from
  your own phone stay on your machine and are not committed.
- **Kernel changes are published as patches** to Apple's open-source XNU
  (xnu-8796, [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu)),
  which is licensed under the Apple Public Source License 2.0 (APSL). The patches in
  `xnu/patches/` are derivative works and are offered under the same license. You need the
  original XNU source to apply them.
- **Original code in this fork** (the Mali GPU driver glue, the Metal plug-in, tools and
  scripts written for this fork) is under the MIT license, see [LICENSE](LICENSE) for the exact
  scope. Code carrying a different license or SPDX header keeps it. See [NOTICE](NOTICE).

## Interoperability and research

The goal is to run software on hardware its owner already has, and to learn how it works. The
project does not circumvent copy protection on content, does not distribute copyrighted
works, and does not support piracy. Features that switch off Apple's code-signing, sandbox or
secure-boot checks exist only so that a research kernel can boot on non-Apple hardware, and make
the device **insecure**. Do not store personal data on it.

## No warranty, use at your own risk

The software is provided "as is", without warranty of any kind. Flashing boot images and
repartitioning storage can **permanently erase data and can brick a device**. Back up your
partitions and boot image first. The authors are not liable for any damage, data loss or
warranty claim. Bootloader unlocking may void your warranty. You are responsible for following
the laws and terms that apply to you, including Apple's and Samsung's software license
agreements for any software you supply.

## Reporting a problem

If you believe something here infringes your rights, open a GitHub issue with the file path
and the reason, or use GitHub's own takedown process. Please give us a chance to fix it.
