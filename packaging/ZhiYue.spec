# RPM spec for RBWA (Read Book With AI) -- x86_64.
#
# Requires the release bundle to be built first:
#   flutter build linux --release
# Then:
#   rpmbuild -bb packaging/ZhiYue.spec
#
# The bundle's RPATH is $ORIGIN/lib, so the exe and its lib/ dir must stay
# together under %%{_libdir}/zhiyue; /usr/bin/ZhiYue is a symlink (the kernel
# resolves $ORIGIN against the real path).

%global __requires_exclude_from ^%{_libdir}/zhiyue/lib/.*$

Name:           ZhiYue
Version:        0.1.0
Release:        1%{?dist}
Summary:        智阅 - AI-powered local PDF/image reader
License:        MIT OR Apache-2.0
URL:            https://github.com/CSY2569/Zhiyue
BuildArch:      x86_64

# Runtime dependencies (major desktop distributions ship these)
Requires:       gtk3 >= 3.22
Requires:       glib2 >= 2.50
Requires:       glibc >= 2.31
Requires:       libstdc++ >= 9
Requires:       fontconfig >= 2.12
Requires:       libX11
Requires:       pango >= 1.40
Requires:       cairo >= 1.14
Requires:       libxkbcommon >= 0.8
Requires:       harfbuzz >= 2.0
Requires:       freetype >= 2.8
Requires:       libpng
Requires:       libicu
Requires:       sqlite >= 3.30
Requires:       libxml2 >= 2.9
Requires:       dbus >= 1.12
Requires:       google-noto-sans-cjk-fonts

%description
智阅（ZhiYue）- Local PDF/image reader with AI integration: text selection,
annotations, full-page OCR (PP-OCRv4, fully offline), full-text search and
AI chat / translate / explain (BYOK, OpenAI-compatible).

OCR models (both modes) are bundled with the package.

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_libdir}/zhiyue/lib
install -d %{buildroot}%{_datadir}/applications
install -d %{buildroot}%{_datadir}/icons/hicolor/512x512/apps
install -d %{buildroot}%{_datadir}/licenses/zhiyue

install -m 755 %{_sourcedir}/bundle/ZhiYue %{buildroot}%{_libdir}/zhiyue/ZhiYue
cp -a %{_sourcedir}/bundle/lib/*.so %{buildroot}%{_libdir}/zhiyue/lib/
cp -a %{_sourcedir}/bundle/data %{buildroot}%{_libdir}/zhiyue/data
cp -a %{_sourcedir}/bundle/models %{buildroot}%{_libdir}/zhiyue/models
ln -s ../lib/zhiyue/ZhiYue %{buildroot}%{_bindir}/ZhiYue
install -m 644 %{_sourcedir}/packaging/ZhiYue.desktop \
  %{buildroot}%{_datadir}/applications/ZhiYue.desktop
install -m 644 %{_sourcedir}/packaging/icon/zhiyue.png \
  %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/zhiyue.png
install -m 644 %{_sourcedir}/LICENSE %{buildroot}%{_datadir}/licenses/zhiyue/LICENSE

%files
%license %{_datadir}/licenses/zhiyue/LICENSE
%{_bindir}/ZhiYue
%{_libdir}/zhiyue/ZhiYue
%{_libdir}/zhiyue/lib/*
%{_libdir}/zhiyue/data/
%{_libdir}/zhiyue/models/
%{_datadir}/applications/ZhiYue.desktop
%{_datadir}/icons/hicolor/512x512/apps/zhiyue.png

%changelog
* Mon Aug 10 2026 ZhiYue <zhiyue@localhost> - 0.1.0-1
- Initial package.
