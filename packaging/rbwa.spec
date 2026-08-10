# RPM spec for RBWA (Read Book With AI) -- x86_64.
#
# Requires the release bundle to be built first:
#   flutter build linux --release
# Then:
#   rpmbuild -bb packaging/rbwa.spec
#
# The bundle's RPATH is $ORIGIN/lib, so the exe and its lib/ dir must stay
# together under %%{_libdir}/rbwa; /usr/bin/rbwa is a symlink (the kernel
# resolves $ORIGIN against the real path).

%global __requires_exclude_from ^%{_libdir}/rbwa/lib/.*$

Name:           rbwa
Version:        0.1.0
Release:        1%{?dist}
Summary:        Read Book With AI - AI-powered local PDF/image reader
License:        MIT OR Apache-2.0
URL:            https://localhost/rbwa
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
Local PDF/image reader with AI integration: text selection, annotations,
full-page OCR (PP-OCRv4, fully offline), full-text search and AI chat /
translate / explain (BYOK, OpenAI-compatible).

Requires OCR models: run scripts/download_ocr_models.sh to fetch the
PP-OCRv4 models before the first scan.

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_libdir}/rbwa/lib
install -d %{buildroot}%{_datadir}/applications
install -d %{buildroot}%{_datadir}/icons/hicolor/512x512/apps

install -m 755 %{_sourcedir}/bundle/rbwa %{buildroot}%{_libdir}/rbwa/rbwa
cp -a %{_sourcedir}/bundle/lib/*.so %{buildroot}%{_libdir}/rbwa/lib/
cp -a %{_sourcedir}/bundle/data %{buildroot}%{_libdir}/rbwa/data
ln -s ../lib/rbwa/rbwa %{buildroot}%{_bindir}/rbwa
install -m 644 %{_sourcedir}/packaging/rbwa.desktop \
  %{buildroot}%{_datadir}/applications/rbwa.desktop
install -m 644 %{_sourcedir}/packaging/icon/rbwa.png \
  %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/rbwa.png

%files
%{_bindir}/rbwa
%{_libdir}/rbwa/rbwa
%{_libdir}/rbwa/lib/*
%{_libdir}/rbwa/data/
%{_datadir}/applications/rbwa.desktop
%{_datadir}/icons/hicolor/512x512/apps/rbwa.png

%changelog
* Mon Aug 10 2026 RBWA <rbwa@localhost> - 0.1.0-1
- Initial package.
