# Third-party notices

Copyright (c) 2026 John Lightfoot

Kiloview Environment Setup is an independent project. It is not affiliated
with, sponsored, approved, or endorsed by Kiloview, Vizrt NDI AB, Microsoft,
Canonical, or Docker.

The project's original source code, documentation, executable launcher, and
artwork are licensed under the MIT License in `LICENSE`. That licence does not
apply to software or services obtained from third parties by the installer.

## Kiloview KiloLink Server Pro

The installer retrieves the official `kiloview/klnk-pro` container image from
the vendor's distribution service. The image is not included in this
repository and remains subject to Kiloview's separate licence terms. Users
must review and accept those terms before installation.

Vendor licence source: <https://www.kiloview.com/downloads/klnk-pro/install.sh>.
This installer's free-use permission does not grant a KiloLink product entitlement.

Kiloview, KiloLink, and associated names and marks belong to their respective
owners.

## NDI Tools and NDI Discovery Server

The installer retrieves NDI Tools from NDI's official distribution service at
installation time. NDI Tools and NDI Discovery Server are not included in this
repository and remain subject to their separate vendor terms.

NDI® is a registered trademark of Vizrt NDI AB.

Vendor licence: <https://docs.ndi.video/all/using-ndi/ndi-tools/installing-ndi-tools/software-license-agreement>.
The vendor's installed `Licenses` directory contains its bundled-component
notices. Codec/patent permissions are not granted by this installer. NDI Tools
is downloaded directly for the end user; do not redistribute it inside this setup.

## NDI Configurator PC Agent

Client setup downloads the unmodified complete Windows release from
<https://github.com/JohnDevAc/Kiloview-PC-Onboarding>. The PC Agent package is
not embedded in this repository or relicensed under MIT. It remains a separate
product with its own proprietary licence, artwork, installation and update feed.
Its native setup presents its licence before a new installation. See
<https://github.com/JohnDevAc/Kiloview-PC-Onboarding/blob/main/LICENSE.md>.

Copyright (c) 2026 John Lightfoot. Its currently published licence is Proprietary
Non-Commercial No-Derivatives, version 1.0. Commercial use requires separate
terms from its licensor. Preserve the release's `LICENSE.md` and
`THIRD-PARTY-NOTICES` directory, including notices for its bundled .NET runtime.
The free MIT licence for Environment Setup does not override those terms.

## WiX Toolset 5.0.2 — included in the setup executable

Copyright (c) .NET Foundation and contributors.

The setup bundle includes unmodified WiX Burn and standard bootstrapper application
code under the Microsoft Reciprocal License (MS-RL). The complete licence is
installed as `licenses/WiX-5.0.2.txt`. The corresponding upstream source archive
is supplied as `licenses/wix-5.0.2-source.zip`; source and build files are also
available at <https://github.com/wixtoolset/wix/tree/v5.0.2>.
Retain these notices, licence and source when redistributing the setup bundle.
John Lightfoot's separate original files remain under MIT.

## Platform components

Windows, Windows Subsystem for Linux, Ubuntu, Docker Engine, containerd, and
other packages installed or used by this project are not relicensed by this
project. They remain subject to the licences and terms supplied by their
respective copyright holders and vendors.

These packages are obtained from their vendors or configured Ubuntu repositories,
not embedded in the setup bundle. This list describes direct dependencies, not a
complete licence inventory for every changing vendor image or Linux package.

| Component | Licence / authoritative notice location |
| --- | --- |
| Windows and .NET Framework used by the launcher | Microsoft terms supplied with Windows; no .NET Framework redistributable is bundled |
| WSL | Microsoft distribution terms and component notices; open-source WSL code uses MIT: <https://github.com/microsoft/WSL/blob/master/LICENSE> |
| Ubuntu and Linux kernel | Individual package licences; see `/usr/share/doc/<package>/copyright`, `/usr/share/common-licenses`, and <https://ubuntu.com/legal/intellectual-property-policy> |
| Docker Engine / Moby | Apache-2.0 and component notices: <https://github.com/moby/moby/blob/master/LICENSE> |
| Docker CLI, Buildx and Compose | Apache-2.0 and repository notices: <https://github.com/docker/cli>, <https://github.com/docker/buildx>, <https://github.com/docker/compose> |
| containerd | Apache-2.0 and component notices: <https://github.com/containerd/containerd/blob/main/LICENSE> |
| Avahi and libnss-mdns | LGPL-2.1 and package notices: <https://github.com/avahi/avahi/blob/master/LICENSE>, <https://github.com/avahi/nss-mdns> |
| D-Bus, curl, GnuPG, iproute2, CA certificates, util-linux and core Linux tools | Individual Ubuntu package copyright files; upstream terms and source accompany the distribution |

Ubuntu's source repositories provide corresponding sources for repository
packages. Preserve the package-specific notices and comply with their licences
if distributing a prepared WSL image or offline dependency bundle. This project
does not distribute such an image. Installing Docker Engine does not install
Docker Desktop or grant a Docker Desktop subscription.

Build/test tools such as the .NET SDK and Git for Windows are development
dependencies and are not shipped as runtime payloads. Review dependency notices
again when changing the installer toolchain or vendor packaging.
