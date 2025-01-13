Name:           mixologist
Version:        0.0.1
Release:        %autorelease
Summary:        Tool to allow mixing audio between different programs

License:        MIT
URL:            https://cstring.dev
Source0:        https://cstring.dev/mixologist-0.0.1.tar.gz
Source1:        https://github.com/odin-lang/Odin/releases/download/dev-2024-12/odin-linux-amd64-dev-2024-12.tar.gz

BuildRequires: tar, make, systemd-rpm-macros
BuildRequires: clang
Requires: pipewire       

%global debug_package %{nil}
%description
Tool to allow mixing audio between different programs

%prep
%setup -q

%build
%make_build

%install
rm -rf %{buildroot}
%make_install

%post
%systemd_user_post mixd.service

%preun
%systemd_user_preun mixd.service

%postun
%systemd_user_postun_with_restart mixd.service

%files
%license LICENSE
%{_bindir}/mixd
%{_bindir}/mixcli
%{_userunitdir}/mixd.service
%{_userpresetdir}/50-mixd.preset


%changelog
* Tue Dec 03 2024 A1029384756 <hayden.gray104@gmail.com>
- 
