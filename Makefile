# Make targets:
#
#  all    : builds all binaries in development mode, without web assets (default)
#  full   : builds all binaries for PRODUCTION use
#  release: prepares a release tarball
#  clean  : removes all build artifacts
#  test   : runs tests

# To update the Teleport version, update VERSION variable:
# Naming convention:
#   Stable releases:   "1.0.0"
#   Pre-releases:      "1.0.0-alpha.1", "1.0.0-beta.2", "1.0.0-rc.3"
#   Master/dev branch: "1.0.0-dev"
VERSION=13.0.0-dev

DOCKER_IMAGE ?= teleport

GOPATH ?= $(shell go env GOPATH)

# These are standard autotools variables, don't change them please
ifneq ("$(wildcard /bin/bash)","")
SHELL := /bin/bash -o pipefail
endif
BUILDDIR ?= build
BINDIR ?= /usr/local/bin
DATADIR ?= /usr/local/share/teleport
ADDFLAGS ?=
PWD ?= `pwd`
TELEPORT_DEBUG ?= false
GITTAG=v$(VERSION)
CGOFLAG ?= CGO_ENABLED=1

# When TELEPORT_DEBUG is true, set flags to produce
# debugger-friendly builds.
ifeq ("$(TELEPORT_DEBUG)","true")
BUILDFLAGS ?= $(ADDFLAGS) -gcflags=all="-N -l"
else
BUILDFLAGS ?= $(ADDFLAGS) -ldflags '-w -s' -trimpath
endif

OS ?= $(shell go env GOOS)
ARCH ?= $(shell go env GOARCH)
FIPS ?=
RELEASE = teleport-$(GITTAG)-$(OS)-$(ARCH)-bin

# FIPS support must be requested at build time.
FIPS_MESSAGE := without-FIPS-support
ifneq ("$(FIPS)","")
FIPS_TAG := fips
FIPS_MESSAGE := "with-FIPS-support"
RELEASE = teleport-$(GITTAG)-$(OS)-$(ARCH)-fips-bin
endif

# PAM support will only be built into Teleport if headers exist at build time.
PAM_MESSAGE := without-PAM-support
ifneq ("$(wildcard /usr/include/security/pam_appl.h)","")
PAM_TAG := pam
PAM_MESSAGE := "with-PAM-support"
else
# PAM headers for Darwin live under /usr/local/include/security instead, as SIP
# prevents us from modifying/creating /usr/include/security on newer versions of MacOS
ifneq ("$(wildcard /usr/local/include/security/pam_appl.h)","")
PAM_TAG := pam
PAM_MESSAGE := "with-PAM-support"
endif
endif

# BPF support will only be built into Teleport if headers exist at build time.
BPF_MESSAGE := without-BPF-support

# We don't compile BPF for anything except regular non-FIPS linux/amd64 for now, as other builds
# have compilation issues that require fixing.
with_bpf := no
ifeq ("$(OS)","linux")
ifeq ("$(ARCH)","amd64")
ifneq ("$(wildcard /usr/include/bpf/libbpf.h)","")
with_bpf := yes
BPF_TAG := bpf
BPF_MESSAGE := "with-BPF-support"
CLANG ?= $(shell which clang || which clang-10)
CLANG_FORMAT ?= $(shell which clang-format || which clang-format-10)
LLVM_STRIP ?= $(shell which llvm-strip || which llvm-strip-10)
KERNEL_ARCH := $(shell uname -m | sed 's/x86_64/x86/')
INCLUDES :=
ER_BPF_BUILDDIR := lib/bpf/bytecode
RS_BPF_BUILDDIR := lib/restrictedsession/bytecode

# Get Clang's default includes on this system. We'll explicitly add these dirs
# to the includes list when compiling with `-target bpf` because otherwise some
# architecture-specific dirs will be "missing" on some architectures/distros -
# headers such as asm/types.h, asm/byteorder.h, asm/socket.h, asm/sockios.h,
# sys/cdefs.h etc. might be missing.
#
# Use '-idirafter': Don't interfere with include mechanics except where the
# build would have failed anyways.
CLANG_BPF_SYS_INCLUDES = $(shell $(CLANG) -v -E - </dev/null 2>&1 \
	| sed -n '/<...> search starts here:/,/End of search list./{ s| \(/.*\)|-idirafter \1|p }')

STATIC_LIBS += -lbpf -lelf -lz
endif
endif
endif

# Check if rust and cargo are installed before compiling
CHECK_CARGO := $(shell cargo --version 2>/dev/null)
CHECK_RUST := $(shell rustc --version 2>/dev/null)

with_rdpclient := no
RDPCLIENT_MESSAGE := without-Windows-RDP-client

CARGO_TARGET_darwin_amd64 := x86_64-apple-darwin
CARGO_TARGET_darwin_arm64 := aarch64-apple-darwin
CARGO_TARGET_linux_arm64 := aarch64-unknown-linux-gnu
CARGO_TARGET_linux_amd64 := x86_64-unknown-linux-gnu

CARGO_TARGET := --target=${CARGO_TARGET_${OS}_${ARCH}}

ifneq ($(CHECK_RUST),)
ifneq ($(CHECK_CARGO),)

# Do not build RDP client on ARM or 386.
ifneq ("$(ARCH)","arm")
ifneq ("$(ARCH)","386")
with_rdpclient := yes
RDPCLIENT_MESSAGE := "with-Windows-RDP-client"
RDPCLIENT_TAG := desktop_access_rdp
endif
endif

endif
endif

# Enable libfido2 for testing?
# Eagerly enable if we detect the package, we want to test as much as possible.
ifeq ("$(shell pkg-config libfido2 2>/dev/null; echo $$?)", "0")
LIBFIDO2_TEST_TAG := libfido2
endif

# Build tsh against libfido2?
# FIDO2=yes and FIDO2=static enable static libfido2 builds.
# FIDO2=dynamic enables dynamic libfido2 builds.
LIBFIDO2_MESSAGE := without-libfido2
ifneq (, $(filter $(FIDO2), yes static))
LIBFIDO2_MESSAGE := with-libfido2
LIBFIDO2_BUILD_TAG := libfido2 libfido2static
else ifeq ("$(FIDO2)", "dynamic")
LIBFIDO2_MESSAGE := with-libfido2
LIBFIDO2_BUILD_TAG := libfido2
endif

# Enable Touch ID builds?
# Only build if TOUCHID=yes to avoid issues when cross-compiling to 'darwin'
# from other systems.
TOUCHID_MESSAGE := without-Touch-ID
ifeq ("$(TOUCHID)", "yes")
TOUCHID_MESSAGE := with-Touch-ID
TOUCHID_TAG := touchid
endif

# Enable PIV for testing?
# Eagerly enable if we detect the dynamic libpcsclite library, we want to test as much as possible.
ifeq ("$(shell pkg-config libpcsclite 2>/dev/null; echo $$?)", "0")
# This test tag should not be used for builds/releases, only tests.
PIV_TEST_TAG := piv
endif

# Build teleport/api with PIV? This requires the libpcsclite library for linux.
#
# PIV=yes and PIV=static enable static piv builds. This is used by the build
# process to link a static library of libpcsclite for piv-go to connect to.
#
# PIV=dynamic enables dynamic piv builds. This can be used for local
# builds and runs utilizing a dynamic libpcsclite library - `apt get install libpcsclite-dev`
PIV_MESSAGE := without-PIV-support
ifneq (, $(filter $(PIV), yes static dynamic))
PIV_MESSAGE := with-PIV-support
PIV_BUILD_TAG := piv
ifneq ("$(PIV)", "dynamic")
# Link static pcsc libary. By default, piv-go will look for the dynamic library.
# https://github.com/go-piv/piv-go/blob/master/piv/pcsc_unix.go#L23
STATIC_LIBS += -lpcsclite
STATIC_LIBS_TSH += -lpcsclite
endif
endif

# Reproducible builds are only available on select targets, and only when OS=linux.
REPRODUCIBLE ?=
ifneq ("$(OS)","linux")
REPRODUCIBLE = no
endif

# On Windows only build tsh. On all other platforms build teleport, tctl,
# and tsh.
BINARIES=$(BUILDDIR)/teleport $(BUILDDIR)/tctl $(BUILDDIR)/tsh $(BUILDDIR)/tbot
ifeq ("$(OS)","windows")
BINARIES=$(BUILDDIR)/tsh
endif

# Joins elements of the list in arg 2 with the given separator.
#   1. Element separator.
#   2. The list.
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
join-with = $(subst $(SPACE),$1,$(strip $2))

# Separate TAG messages into comma-separated WITH and WITHOUT lists for readability.

COMMA := ,
MESSAGES := $(PAM_MESSAGE) $(FIPS_MESSAGE) $(BPF_MESSAGE) $(RDPCLIENT_MESSAGE) $(LIBFIDO2_MESSAGE) $(TOUCHID_MESSAGE) $(PIV_MESSAGE)
WITH := $(subst -," ",$(call join-with,$(COMMA) ,$(subst with-,,$(filter with-%,$(MESSAGES)))))
WITHOUT := $(subst -," ",$(call join-with,$(COMMA) ,$(subst without-,,$(filter without-%,$(MESSAGES)))))
RELEASE_MESSAGE := "Building with GOOS=$(OS) GOARCH=$(ARCH) REPRODUCIBLE=$(REPRODUCIBLE) and with $(WITH) and without $(WITHOUT)."

# On platforms that support reproducible builds, ensure the archive is created in a reproducible manner.
TAR_FLAGS ?=
ifeq ("$(REPRODUCIBLE)","yes")
TAR_FLAGS = --sort=name --owner=root:0 --group=root:0 --mtime='UTC 2015-03-02' --format=gnu
endif

VERSRC = version.go gitref.go api/version.go

KUBECONFIG ?=
TEST_KUBE ?=
export

TEST_LOG_DIR = ${abspath ./test-logs}

CLANG_FORMAT_STYLE = '{ColumnLimit: 100, IndentWidth: 4, Language: Proto}'

# Is this build targeting the same OS & architecture it is being compiled on, or
# will it require cross-compilation? We need to know this (especially for ARM) so we
# can set the cross-compiler path (and possibly feature flags) correctly.
IS_NATIVE_BUILD ?= $(if $(filter $(ARCH), $(shell go env GOARCH)),"yes","no")

# Set CGOFLAG and BUILDFLAGS as needed for the OS/ARCH.
ifeq ("$(OS)","linux")
ifeq ("$(ARCH)","amd64")
# Link static version of libraries required by Teleport (bpf, pcsc) to reduce system dependencies. Avoid dependencies on dynamic libraries if we already link the static version using --as-needed.
CGOFLAG = CGO_ENABLED=1 CGO_LDFLAGS="-Wl,-Bstatic $(STATIC_LIBS) -Wl,-Bdynamic -Wl,--as-needed"
CGOFLAG_TSH = CGO_ENABLED=1 CGO_LDFLAGS="-Wl,-Bstatic $(STATIC_LIBS_TSH) -Wl,-Bdynamic -Wl,--as-needed"
else ifeq ("$(ARCH)","arm")
# ARM builds need to specify the correct C compiler
CGOFLAG = CGO_ENABLED=1 CC=arm-linux-gnueabihf-gcc
# Add -debugtramp=2 to work around 24 bit CALL/JMP instruction offset.
BUILDFLAGS = $(ADDFLAGS) -ldflags '-w -s -debugtramp=2' -trimpath
else ifeq ("$(ARCH)","arm64")
# ARM64 requires CGO but does not need to do any special linkage due to its reduced featureset
CGOFLAG = CGO_ENABLED=1

# If we 're not guaranteed to be building natively on an arm64 system, then we'll
# need to configure the cross compiler.
ifeq ($(IS_NATIVE_BUILD),"no")
CGOFLAG += CC=aarch64-linux-gnu-gcc
endif

endif
endif

# Windows requires extra parameters to cross-compile with CGO.
ifeq ("$(OS)","windows")
ARCH ?= amd64
ifneq ("$(ARCH)","amd64")
$(error "Building for windows requires ARCH=amd64")
endif
CGOFLAG = CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++
BUILDFLAGS = $(ADDFLAGS) -ldflags '-w -s' -trimpath -buildmode=exe
endif

CGOFLAG_TSH ?= $(CGOFLAG)

#
# 'make all' builds all 3 executables and places them in the current directory.
#
# IMPORTANT:
# Unless called with the `WEBASSETS_TAG` env variable set to "webassets_embed"
# the binaries will not contain the web UI assets and `teleport` won't start
# without setting the environment variable DEBUG=1.
.PHONY: all
all: version
	@echo "---> Building OSS binaries."
	$(MAKE) $(BINARIES)

#
# make binaries builds all binaries defined in the BINARIES environment variable
#
.PHONY: binaries
binaries:
	$(MAKE) $(BINARIES)

# By making these 3 targets below (tsh, tctl and teleport) PHONY we are solving
# several problems:
# * Build will rely on go build internal caching https://golang.org/doc/go1.10 at all times
# * Manual change detection was broken on a large dependency tree
# If you are considering changing this behavior, please consult with dev team first
.PHONY: $(BUILDDIR)/tctl
$(BUILDDIR)/tctl:
	GOOS=$(OS) GOARCH=$(ARCH) $(CGOFLAG) go build -tags "$(PAM_TAG) $(FIPS_TAG) $(PIV_BUILD_TAG)" -o $(BUILDDIR)/tctl $(BUILDFLAGS) ./tool/tctl

.PHONY: $(BUILDDIR)/teleport
$(BUILDDIR)/teleport: ensure-webassets bpf-bytecode rdpclient
	GOOS=$(OS) GOARCH=$(ARCH) $(CGOFLAG) go build -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG) $(WEBASSETS_TAG) $(RDPCLIENT_TAG) $(PIV_BUILD_TAG)" -o $(BUILDDIR)/teleport $(BUILDFLAGS) ./tool/teleport

# NOTE: Any changes to the `tsh` build here must be copied to `windows.go` in Dronegen until
# 		we can use this Makefile for native Windows builds.
.PHONY: $(BUILDDIR)/tsh
$(BUILDDIR)/tsh:
	GOOS=$(OS) GOARCH=$(ARCH) $(CGOFLAG_TSH) go build -tags "$(FIPS_TAG) $(LIBFIDO2_BUILD_TAG) $(TOUCHID_TAG) $(PIV_BUILD_TAG)" -o $(BUILDDIR)/tsh $(BUILDFLAGS) ./tool/tsh

.PHONY: $(BUILDDIR)/tbot
$(BUILDDIR)/tbot:
	GOOS=$(OS) GOARCH=$(ARCH) $(CGOFLAG) go build -tags "$(FIPS_TAG)" -o $(BUILDDIR)/tbot $(BUILDFLAGS) ./tool/tbot

#
# BPF support (IF ENABLED)
# Requires a recent version of clang and libbpf installed.
#
ifeq ("$(with_bpf)","yes")
$(ER_BPF_BUILDDIR):
	mkdir -p $(ER_BPF_BUILDDIR)

$(RS_BPF_BUILDDIR):
	mkdir -p $(RS_BPF_BUILDDIR)

# Build BPF code
$(ER_BPF_BUILDDIR)/%.bpf.o: bpf/enhancedrecording/%.bpf.c $(wildcard bpf/*.h) | $(ER_BPF_BUILDDIR)
	$(CLANG) -g -O2 -target bpf -D__TARGET_ARCH_$(KERNEL_ARCH) $(INCLUDES) $(CLANG_BPF_SYS_INCLUDES) -c $(filter %.c,$^) -o $@
	$(LLVM_STRIP) -g $@ # strip useless DWARF info

# Build BPF code
$(RS_BPF_BUILDDIR)/%.bpf.o: bpf/restrictedsession/%.bpf.c $(wildcard bpf/*.h) | $(RS_BPF_BUILDDIR)
	$(CLANG) -g -O2 -target bpf -D__TARGET_ARCH_$(KERNEL_ARCH) $(INCLUDES) $(CLANG_BPF_SYS_INCLUDES) -c $(filter %.c,$^) -o $@
	$(LLVM_STRIP) -g $@ # strip useless DWARF info

.PHONY: bpf-rs-bytecode
bpf-rs-bytecode: $(RS_BPF_BUILDDIR)/restricted.bpf.o

.PHONY: bpf-er-bytecode
bpf-er-bytecode: $(ER_BPF_BUILDDIR)/command.bpf.o $(ER_BPF_BUILDDIR)/disk.bpf.o $(ER_BPF_BUILDDIR)/network.bpf.o $(ER_BPF_BUILDDIR)/counter_test.bpf.o

.PHONY: bpf-bytecode
bpf-bytecode: bpf-er-bytecode bpf-rs-bytecode

# Generate vmlinux.h based on the installed kernel
.PHONY: update-vmlinux-h
update-vmlinux-h:
	bpftool btf dump file /sys/kernel/btf/vmlinux format c >bpf/vmlinux.h

else
.PHONY: bpf-bytecode
bpf-bytecode:
endif

ifeq ("$(with_rdpclient)", "yes")
.PHONY: rdpclient
rdpclient:
ifneq ("$(FIPS)","")
	cargo build -p rdp-client --features=fips --release $(CARGO_TARGET)
else
	cargo build -p rdp-client --release $(CARGO_TARGET)
endif
else
.PHONY: rdpclient
rdpclient:
endif

#
# make full - Builds Teleport binaries with the built-in web assets and
# places them into $(BUILDDIR). On Windows, this target is skipped because
# only tsh is built.
#
.PHONY:full
full: ensure-webassets
ifneq ("$(OS)", "windows")
	$(MAKE) all WEBASSETS_TAG="webassets_embed"
endif

#
# make full-ent - Builds Teleport enterprise binaries
#
.PHONY:full-ent
full-ent: ensure-webassets-e
ifneq ("$(OS)", "windows")
	@if [ -f e/Makefile ]; then $(MAKE) -C e full; fi
endif

#
# make clean - Removes all build artifacts.
#
.PHONY: clean
clean: clean-ui
	@echo "---> Cleaning up OSS build artifacts."
	rm -rf $(BUILDDIR)
# Check if the variable is set to prevent calling remove on the root directory.
ifneq ($(ER_BPF_BUILDDIR),)
	rm -f $(ER_BPF_BUILDDIR)/*.o
endif
ifneq ($(RS_BPF_BUILDDIR),)
	rm -f $(RS_BPF_BUILDDIR)/*.o
endif
	-cargo clean
	-go clean -cache
	rm -f *.gz
	rm -f *.zip
	rm -f gitref.go
	rm -rf build.assets/tooling/bin

.PHONY: clean-ui
clean-ui:
	rm -rf webassets/*
	find . -type d -name node_modules -prune -exec rm -rf {} \;

#
# make release - Produces a binary release tarball.
#
.PHONY:
export
release:
	@echo "---> OSS $(RELEASE_MESSAGE)"
ifeq ("$(OS)", "windows")
	$(MAKE) --no-print-directory release-windows
else ifeq ("$(OS)", "darwin")
	$(MAKE) --no-print-directory release-darwin
else
	$(MAKE) --no-print-directory release-unix
endif

# These are aliases used to make build commands uniform.
.PHONY: release-amd64
release-amd64:
	$(MAKE) release ARCH=amd64

.PHONY: release-386
release-386:
	$(MAKE) release ARCH=386

.PHONY: release-arm
release-arm:
	$(MAKE) release ARCH=arm

.PHONY: release-arm64
release-arm64:
	$(MAKE) release ARCH=arm64

#
# make build-archive - Packages the results of a build into a release tarball
#
.PHONY: build-archive
build-archive:
	@echo "---> Creating OSS release archive."
	mkdir teleport
	cp -rf $(BUILDDIR)/* \
		examples \
		build.assets/install\
		README.md \
		CHANGELOG.md \
		teleport/
	echo $(GITTAG) > teleport/VERSION
	tar $(TAR_FLAGS) -c teleport | gzip -n > $(RELEASE).tar.gz
	rm -rf teleport
	@echo "---> Created $(RELEASE).tar.gz."

#
# make release-unix - Produces binary release tarballs for both OSS and
# Enterprise editions, containing teleport, tctl, tbot and tsh.
#
.PHONY:
release-unix: clean full build-archive
	@if [ -f e/Makefile ]; then $(MAKE) -C e release; fi

.PHONY: release-darwin-unsigned
release-darwin-unsigned: RELEASE:=$(RELEASE)-unsigned
release-darwin-unsigned: clean full build-archive

.PHONY: release-darwin
release-darwin: ABSOLUTE_BINARY_PATHS:=$(addprefix $(CURDIR)/,$(BINARIES))
release-darwin: release-darwin-unsigned
	# Only run if Apple username/pass for notarization are provided
	if [ -n "$$APPLE_USERNAME" -a -n "$$APPLE_PASSWORD" ]; then \
		cd ./build.assets/tooling/ && \
		go run ./cmd/notarize-apple-binaries/*.go \
			--log-level=debug $(ABSOLUTE_BINARY_PATHS); \
	fi
	$(MAKE) build-archive
	@if [ -f e/Makefile ]; then $(MAKE) -C e release; fi

#
# make release-unix-only - Produces an Enterprise binary release tarball containing
# teleport, tctl, and tsh *WITHOUT* also creating an OSS build tarball.
#
.PHONY: release-unix-only
release-unix-only: clean
	@if [ -f e/Makefile ]; then $(MAKE) -C e release; fi

#
# make release-windows-unsigned - Produces a binary release archive containing only tsh.
#
.PHONY: release-windows-unsigned
release-windows-unsigned: clean all
	@echo "---> Creating OSS release archive."
	mkdir teleport
	cp -rf $(BUILDDIR)/* \
		README.md \
		CHANGELOG.md \
		teleport/
	mv teleport/tsh teleport/tsh-unsigned.exe
	echo $(GITTAG) > teleport/VERSION
	zip -9 -y -r -q $(RELEASE)-unsigned.zip teleport/
	rm -rf teleport/
	@echo "---> Created $(RELEASE)-unsigned.zip."

#
# make release-windows - Produces an archive containing a signed release of
# tsh.exe
#
.PHONY: release-windows
release-windows: release-windows-unsigned
	@if [ ! -f "windows-signing-cert.pfx" ]; then \
		echo "windows-signing-cert.pfx is missing or invalid, cannot create signed archive."; \
		exit 1; \
	fi

	rm -rf teleport
	@echo "---> Extracting $(RELEASE)-unsigned.zip"
	unzip $(RELEASE)-unsigned.zip

	@echo "---> Signing Windows binary."
	@osslsigncode sign \
		-pkcs12 "windows-signing-cert.pfx" \
		-n "Teleport" \
		-i https://goteleport.com \
		-t http://timestamp.digicert.com \
		-h sha2 \
		-in teleport/tsh-unsigned.exe \
		-out teleport/tsh.exe; \
	success=$$?; \
	rm -f teleport/tsh-unsigned.exe; \
	if [ "$${success}" -ne 0 ]; then \
		echo "Failed to sign tsh.exe, aborting."; \
		exit 1; \
	fi

	zip -9 -y -r -q $(RELEASE).zip teleport/
	rm -rf teleport/
	@echo "---> Created $(RELEASE).zip."

#
# Remove trailing whitespace in all markdown files under docs/.
#
# Note: this runs in a busybox container to avoid incompatibilities between
# linux and macos CLI tools.
#
.PHONY:docs-fix-whitespace
docs-fix-whitespace:
	docker run --rm -v $(PWD):/teleport busybox \
		find /teleport/docs/ -type f -name '*.md' -exec sed -E -i 's/\s+$$//g' '{}' \;

#
# Test docs for trailing whitespace and broken links
#
.PHONY:docs-test
docs-test: docs-test-whitespace

#
# Check for trailing whitespace in all markdown files under docs/
#
.PHONY:docs-test-whitespace
docs-test-whitespace:
	if find docs/ -type f -name '*.md' | xargs grep -E '\s+$$'; then \
		echo "trailing whitespace found in docs/ (see above)"; \
		echo "run 'make docs-fix-whitespace' to fix it"; \
		exit 1; \
	fi

#
# Builds some tooling for filtering and displaying test progress/output/etc
#
TOOLINGDIR := ${abspath ./build.assets/tooling}
RENDER_TESTS := $(TOOLINGDIR)/bin/render-tests
$(RENDER_TESTS): $(wildcard $(TOOLINGDIR)/cmd/render-tests/*.go)
	cd $(TOOLINGDIR) && go build -o "$@" ./cmd/render-tests

DIFF_TEST := $(TOOLINGDIR)/bin/difftest
$(DIFF_TEST): $(wildcard $(TOOLINGDIR)/cmd/difftest/*.go)
	cd $(TOOLINGDIR) && go build -o "$@" ./cmd/difftest

.PHONY: tooling
tooling: $(RENDER_TESTS) $(DIFF_TEST)

#
# Runs all Go/shell tests, called by CI/CD.
#
.PHONY: test
test: test-helm test-sh test-ci test-api test-go test-rust test-operator

$(TEST_LOG_DIR):
	mkdir $(TEST_LOG_DIR)

.PHONY: helmunit/installed
helmunit/installed:
	@if ! helm unittest -h >/dev/null; then \
		echo 'Helm unittest plugin is required to test Helm charts. Run `helm plugin install https://github.com/quintush/helm-unittest` to install it'; \
		exit 1; \
	fi

# The CI environment is responsible for setting HELM_PLUGINS to a directory where
# quintish/helm-unittest is installed.
#
# Github Actions build uses /workspace as homedir and Helm can't pick up plugins by default there,
# so override the plugin location via environemnt variable when running in CI. Github Actions provide CI=true
# environment variable.
.PHONY: test-helm
test-helm: helmunit/installed
	helm unittest -3 examples/chart/teleport-cluster
	helm unittest -3 examples/chart/teleport-kube-agent

.PHONY: test-helm-update-snapshots
test-helm-update-snapshots: helmunit/installed
	helm unittest -3 -u examples/chart/teleport-cluster
	helm unittest -3 -u examples/chart/teleport-kube-agent

#
# Runs all Go tests except integration, called by CI/CD.
#
.PHONY: test-go
test-go: test-go-prepare test-go-unit test-go-libfido2 test-go-touch-id test-go-tsh test-go-chaos

# Runs test prepare steps
.PHONY: test-go-prepare
test-go-prepare: ensure-webassets bpf-bytecode rdpclient $(TEST_LOG_DIR) $(RENDER_TESTS) $(VERSRC)

# Runs base unit tests
.PHONY: test-go-unit
test-go-unit: FLAGS ?= -race -shuffle on
test-go-unit: SUBJECT ?= $(shell go list ./... | grep -v -e integration -e tool/tsh -e operator )
test-go-unit:
	$(CGOFLAG) go test -cover -json -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG) $(RDPCLIENT_TAG) $(TOUCHID_TAG) $(PIV_TEST_TAG)" $(PACKAGES) $(SUBJECT) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/unit.json \
		| ${RENDER_TESTS}

# rdpclient and libfido2 don't play well together, so we run libfido2 tests
# separately.
# TODO(codingllama): Run libfido2 tests along with others once RDP doesn't
#  embed openssl/libcrypto.
.PHONY: test-go-libfido2
test-go-libfido2: FLAGS ?= -race -shuffle on
test-go-libfido2: SUBJECT ?= ./lib/auth/webauthncli/...
test-go-libfido2:
ifneq ("$(LIBFIDO2_TEST_TAG)", "")
	$(CGOFLAG) go test -cover -json -tags "$(LIBFIDO2_TEST_TAG)" $(PACKAGES) $(SUBJECT) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/unit.json \
		| ${RENDER_TESTS}
endif

# Make sure untagged touchid code build/tests.
.PHONY: test-go-touch-id
test-go-touch-id: FLAGS ?= -race -shuffle on
test-go-touch-id: SUBJECT ?= ./lib/auth/touchid/...
test-go-touch-id:
ifneq ("$(TOUCHID_TAG)", "")
	$(CGOFLAG) go test -cover -json $(PACKAGES) $(SUBJECT) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/unit.json \
		| ${RENDER_TESTS}
endif

# Runs ci tsh tests
.PHONY: test-go-tsh
test-go-tsh: FLAGS ?= -race -shuffle on
test-go-tsh: SUBJECT ?= github.com/gravitational/teleport/tool/tsh
test-go-tsh:
	$(CGOFLAG_TSH) go test -cover -json -tags "$(PAM_TAG) $(FIPS_TAG) $(LIBFIDO2_TEST_TAG) $(TOUCHID_TAG) $(PIV_TEST_TAG)" $(PACKAGES) $(SUBJECT) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/unit.json \
		| ${RENDER_TESTS}

# Chaos tests have high concurrency, run without race detector and have TestChaos prefix.
.PHONY: test-go-chaos
test-go-chaos: CHAOS_FOLDERS = $(shell find . -type f -name '*chaos*.go' | xargs dirname | uniq)
test-go-chaos:
	$(CGOFLAG) go test -cover -json -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG) $(RDPCLIENT_TAG)" -test.run=TestChaos $(CHAOS_FOLDERS) \
		| tee $(TEST_LOG_DIR)/chaos.json \
		| ${RENDER_TESTS}

# Runs ci scripts tests
.PHONY: test-ci
test-ci: $(TEST_LOG_DIR) $(RENDER_TESTS)
	(cd .cloudbuild/scripts && \
		go test -cover -json ./... \
		| tee $(TEST_LOG_DIR)/ci.json \
		| ${RENDER_TESTS})

#
# Runs all Go tests except integration and chaos, called by CI/CD.
#
UNIT_ROOT_REGEX := ^TestRoot
.PHONY: test-go-root
test-go-root: ensure-webassets bpf-bytecode rdpclient $(TEST_LOG_DIR) $(RENDER_TESTS)
test-go-root: FLAGS ?= -race -shuffle on
test-go-root: PACKAGES = $(shell go list $(ADDFLAGS) ./... | grep -v -e integration -e operator)
test-go-root: $(VERSRC)
	$(CGOFLAG) go test -json -run "$(UNIT_ROOT_REGEX)" -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG) $(RDPCLIENT_TAG)" $(PACKAGES) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/unit-root.json \
		| ${RENDER_TESTS}

#
# Runs Go tests on the api module. These have to be run separately as the package name is different.
#
.PHONY: test-api
test-api: $(VERSRC) $(TEST_LOG_DIR) $(RENDER_TESTS)
test-api: FLAGS ?= -race -shuffle on
test-api: SUBJECT ?= $(shell cd api && go list ./...)
test-api:
	cd api && $(CGOFLAG) go test -json -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG)" $(PACKAGES) $(SUBJECT) $(FLAGS) $(ADDFLAGS) \
		| tee $(TEST_LOG_DIR)/api.json \
		| ${RENDER_TESTS}

#
# Runs Teleport Operator tests.
# We have to run them using the makefile to ensure the installation of the k8s test tools (envtest)
#
.PHONY: test-operator
test-operator:
	make -C operator test

#
# Runs cargo test on our Rust modules.
# (a no-op if cargo and rustc are not installed)
#
ifneq ($(CHECK_RUST),)
ifneq ($(CHECK_CARGO),)
.PHONY: test-rust
test-rust:
	cargo test
else
.PHONY: test-rust
test-rust:
endif
endif

# Find and run all shell script unit tests (using https://github.com/bats-core/bats-core)
.PHONY: test-sh
test-sh:
	@if ! type bats 2>&1 >/dev/null; then \
		echo "Not running 'test-sh' target as 'bats' is not installed."; \
		if [ "$${DRONE}" = "true" ]; then echo "This is a failure when running in CI." && exit 1; fi; \
		exit 0; \
	fi; \
	find . -iname "*.bats" -exec dirname {} \; | uniq | xargs -t -L1 bats $(BATSFLAGS)


.PHONY: run-etcd
run-etcd:
	examples/etcd/start-etcd.sh
#
# Integration tests. Need a TTY to work.
# Any tests which need to run as root must be skipped during regular integration testing.
#
.PHONY: integration
integration: FLAGS ?= -v -race
integration: PACKAGES = $(shell go list ./... | grep integration)
integration:  $(TEST_LOG_DIR) $(RENDER_TESTS)
	@echo KUBECONFIG is: $(KUBECONFIG), TEST_KUBE: $(TEST_KUBE)
	$(CGOFLAG) go test -timeout 30m -json -tags "$(PAM_TAG) $(FIPS_TAG) $(BPF_TAG) $(RDPCLIENT_TAG)" $(PACKAGES) $(FLAGS) \
		| tee $(TEST_LOG_DIR)/integration.json \
		| $(RENDER_TESTS) -report-by test

#
# Integration tests which need to be run as root in order to complete successfully
# are run separately to all other integration tests. Need a TTY to work.
#
INTEGRATION_ROOT_REGEX := ^TestRoot
.PHONY: integration-root
integration-root: FLAGS ?= -v -race
integration-root: PACKAGES = $(shell go list ./... | grep integration)
integration-root: $(TEST_LOG_DIR) $(RENDER_TESTS)
	$(CGOFLAG) go test -json -run "$(INTEGRATION_ROOT_REGEX)" $(PACKAGES) $(FLAGS) \
		| tee $(TEST_LOG_DIR)/integration-root.json \
		| $(RENDER_TESTS) -report-by test

#
# Lint the source code.
# By default lint scans the entire repo. Pass GO_LINT_FLAGS='--new' to only scan local
# changes (or last commit).
#
.PHONY: lint
lint: lint-sh lint-helm lint-api lint-go lint-license lint-rust lint-tools lint-protos

.PHONY: lint-tools
lint-tools: lint-build-tooling lint-ci-scripts lint-backport

#
# Runs the clippy linter on our rust modules
# (a no-op if cargo and rustc are not installed)
#
ifneq ($(CHECK_RUST),)
ifneq ($(CHECK_CARGO),)
.PHONY: lint-rust
lint-rust:
	cargo clippy --locked --all-targets -- -D warnings \
		&& cargo fmt -- --check
else
.PHONY: lint-rust
lint-rust:
endif
endif

.PHONY: lint-go
lint-go: GO_LINT_FLAGS ?=
lint-go:
	golangci-lint run -c .golangci.yml --build-tags='$(LIBFIDO2_TEST_TAG) $(TOUCHID_TAG) $(PIV_TEST_TAG)' $(GO_LINT_FLAGS)

.PHONY: fix-imports
fix-imports:
	make -C build.assets/ fix-imports

.PHONY: fix-imports/host
fix-imports/host:
	@if ! type gci >/dev/null 2>&1; then\
		echo 'gci is not installed or is missing from PATH, consider installing it ("go install github.com/daixiang0/gci@latest") or use "make -C build.assets/ fix-imports"';\
		exit 1;\
	fi
	gci write -s 'standard,default,prefix(github.com/gravitational/teleport)' --skip-generated .

.PHONY: lint-build-tooling
lint-build-tooling: GO_LINT_FLAGS ?=
lint-build-tooling:
	cd build.assets/tooling && golangci-lint run -c ../../.golangci.yml $(GO_LINT_FLAGS)

.PHONY: lint-backport
lint-backport: GO_LINT_FLAGS ?=
lint-backport:
	cd assets/backport && golangci-lint run -c ../../.golangci.yml $(GO_LINT_FLAGS)

.PHONY: lint-ci-scripts
lint-ci-scripts: GO_LINT_FLAGS ?=
lint-ci-scripts:
	cd .cloudbuild/scripts/ && golangci-lint run -c ../../.golangci.yml $(GO_LINT_FLAGS)

# api is no longer part of the teleport package, so golangci-lint skips it by default
.PHONY: lint-api
lint-api: GO_LINT_API_FLAGS ?=
lint-api:
	cd api && golangci-lint run -c ../.golangci.yml $(GO_LINT_API_FLAGS)

# TODO(awly): remove the `--exclude` flag after cleaning up existing scripts
.PHONY: lint-sh
lint-sh: SH_LINT_FLAGS ?=
lint-sh:
	find . -type f -name '*.sh' | xargs \
		shellcheck \
		--exclude=SC2086 \
		$(SH_LINT_FLAGS)

	# lint AWS AMI scripts
	# SC1091 prints errors when "source" directives are not followed
	find assets/aws/files/bin -type f | xargs \
		shellcheck \
		--exclude=SC2086 \
		--exclude=SC1091 \
		--exclude=SC2129 \
		$(SH_LINT_FLAGS)

# Lints all the Helm charts found in directories under examples/chart and exits on failure
# If there is a .lint directory inside, the chart gets linted once for each .yaml file in that directory
# We inherit yamllint's 'relaxed' configuration as it's more compatible with Helm output and will only error on
# show-stopping issues. Kubernetes' YAML parser is not particularly fussy.
# If errors are found, the file is printed with line numbers to aid in debugging.
.PHONY: lint-helm
lint-helm:
	@if ! type yamllint 2>&1 >/dev/null; then \
		echo "Not running 'lint-helm' target as 'yamllint' is not installed."; \
		if [ "$${DRONE}" = "true" ]; then echo "This is a failure when running in CI." && exit 1; fi; \
		exit 0; \
	fi; \
	for CHART in $$(find examples/chart -mindepth 1 -maxdepth 1 -type d); do \
		if [ -d $${CHART}/.lint ]; then \
			for VALUES in $${CHART}/.lint/*.yaml; do \
				export HELM_TEMP=$$(mktemp); \
				echo -n "Using values from '$${VALUES}': "; \
				yamllint -c examples/chart/.lint-config.yaml $${VALUES} || { cat -en $${VALUES}; exit 1; }; \
				helm lint --strict $${CHART} -f $${VALUES} || exit 1; \
				helm template test $${CHART} -f $${VALUES} 1>$${HELM_TEMP} || exit 1; \
				yamllint -c examples/chart/.lint-config.yaml $${HELM_TEMP} || { cat -en $${HELM_TEMP}; exit 1; }; \
			done \
		else \
			export HELM_TEMP=$$(mktemp); \
			helm lint --strict $${CHART} || exit 1; \
			helm template test $${CHART} 1>$${HELM_TEMP} || exit 1; \
			yamllint -c examples/chart/.lint-config.yaml $${HELM_TEMP} || { cat -en $${HELM_TEMP}; exit 1; }; \
		fi; \
	done

ADDLICENSE := $(GOPATH)/bin/addlicense
ADDLICENSE_ARGS := -c 'Gravitational, Inc' -l apache \
		-ignore '**/*.c' \
		-ignore '**/*.h' \
		-ignore '**/*.html' \
		-ignore '**/*.js' \
		-ignore '**/*.py' \
		-ignore '**/*.sh' \
		-ignore '**/*.tf' \
		-ignore '**/*.yaml' \
		-ignore '**/*.yml' \
		-ignore '**/Dockerfile' \
		-ignore 'api/version.go' \
		-ignore 'docs/pages/includes/**/*.go' \
		-ignore 'e/**' \
		-ignore 'gitref.go' \
		-ignore 'lib/srv/desktop/rdp/rdpclient/target/**' \
		-ignore 'lib/teleterm/api/protogen/**' \
		-ignore 'lib/prehog/gen/**' \
		-ignore 'lib/prehog/gen-js/**' \
		-ignore 'lib/web/build/**' \
		-ignore 'version.go' \
		-ignore 'webassets/**' \
		-ignore 'web/**' \
		-ignore 'ignoreme'

.PHONY: lint-license
lint-license: $(ADDLICENSE)
	$(ADDLICENSE) $(ADDLICENSE_ARGS) -check * 2>/dev/null

.PHONY: fix-license
fix-license: $(ADDLICENSE)
	$(ADDLICENSE) $(ADDLICENSE_ARGS) * 2>/dev/null

$(ADDLICENSE):
	cd && go install github.com/google/addlicense@v1.0.0

# This rule updates version files and Helm snapshots based on the Makefile
# VERSION variable.
#
# Used prior to a release by bumping VERSION in this Makefile and then
# running "make update-version".
.PHONY: update-version
update-version: version test-helm-update-snapshots

# This rule triggers re-generation of version files if Makefile changes.
.PHONY: version
version: $(VERSRC)

# This rule triggers re-generation of version files specified if Makefile changes.
$(VERSRC): Makefile
	VERSION=$(VERSION) $(MAKE) -f version.mk setver

# make tag - prints a tag to use with git for the current version
# 	To put a new release on Github:
# 		- bump VERSION variable
# 		- run make setver
# 		- commit changes to git
# 		- build binaries with 'make release'
# 		- run `make tag` and use its output to 'git tag' and 'git push --tags'
.PHONY: update-tag
update-tag:
	@test $(VERSION)
	git tag $(GITTAG)
	git tag api/$(GITTAG)
	(cd e && git tag $(GITTAG) && git push origin $(GITTAG))
	git push origin $(GITTAG) && git push origin api/$(GITTAG)

.PHONY: test-package
test-package: remove-temp-files
	go test -v ./$(p)

.PHONY: test-grep-package
test-grep-package: remove-temp-files
	go test -v ./$(p) -check.f=$(e)

.PHONY: cover-package
cover-package: remove-temp-files
	go test -v ./$(p)  -coverprofile=/tmp/coverage.out
	go tool cover -html=/tmp/coverage.out

.PHONY: profile
profile:
	go tool pprof http://localhost:6060/debug/pprof/profile

.PHONY: sloccount
sloccount:
	find . -o -name "*.go" -print0 | xargs -0 wc -l

.PHONY: remove-temp-files
remove-temp-files:
	find . -name flymake_* -delete

#
# print-go-version outputs Go version as a semver without "go" prefix
#
.PHONY: print-go-version
print-go-version:
	@$(MAKE) -C build.assets print-go-version | sed "s/go//"

# Dockerized build: useful for making Linux releases on OSX
.PHONY:docker
docker:
	make -C build.assets build

# Dockerized build: useful for making Linux binaries on macOS
.PHONY:docker-binaries
docker-binaries: clean
	make -C build.assets build-binaries PIV=$(PIV)

# Interactively enters a Docker container (which you can build and run Teleport inside of)
.PHONY:enter
enter:
	make -C build.assets enter

# Interactively enters a Docker container, as root (which you can build and run Teleport inside of)
.PHONY:enter-root
enter-root:
	make -C build.assets enter-root

# Interactively enters a Docker container (which you can build and run Teleport inside of).
# Similar to `enter`, but uses the centos7 container.
.PHONY:enter/centos7
enter/centos7:
	make -C build.assets enter/centos7

# Interactively enters a Docker container (which you can build and run Teleport Connect inside of).
# Similar to `enter`, but uses the teleterm container.
.PHONY:enter/teleterm
enter/teleterm:
	make -C build.assets enter/teleterm


BUF := buf

# protos/all runs build, lint and format on all protos.
# Use `make grpc` to regenerate protos inside buildbox.
.PHONY: protos/all
protos/all: protos/build protos/lint protos/format

.PHONY: protos/build
protos/build: buf/installed
	$(BUF) build

.PHONY: protos/format
protos/format: buf/installed
	$(BUF) format -w

.PHONY: protos/lint
protos/lint: buf/installed
	$(BUF) lint
	$(BUF) lint --config=api/proto/buf-legacy.yaml api/proto

.PHONY: lint-protos
lint-protos: protos/lint

.PHONY: buf/installed
buf/installed:
	@if ! type -p $(BUF) >/dev/null; then \
		echo 'Buf is required to build/format/lint protos. Follow https://docs.buf.build/installation.'; \
		exit 1; \
	fi

# grpc generates GRPC stubs from service definitions.
# This target runs in the buildbox container.
.PHONY: grpc
grpc:
	$(MAKE) -C build.assets grpc

# grpc/host generates GRPC stubs.
# Unlike grpc, this target runs locally.
.PHONY: grpc/host
grpc/host: protos/all
	@build.assets/genproto.sh

print/env:
	env

# grpc-teleterm generates Go, TypeScript and JavaScript gRPC stubs from definitions for Teleport
# Terminal. This target runs in the buildbox-teleterm container.
#
# It exists as a separate target because on M1 MacBooks we must build grpc_node_plugin from source.
# That involves apt-get install of cmake & build-essential as well pulling hundreds of megabytes of
# git repos. It would significantly increase the time it takes to build buildbox for M1 users that
# don't need to generate Teleterm gRPC files.
# TODO(ravicious): incorporate grpc-teleterm into grpc once grpc-tools adds arm64 binary.
# https://github.com/grpc/grpc-node/issues/1405
.PHONY: grpc-teleterm
grpc-teleterm:
	$(MAKE) -C build.assets grpc-teleterm

# grpc-teleterm/host generates GRPC stubs.
# Unlike grpc-teleterm, this target runs locally.
.PHONY: grpc-teleterm/host
grpc-teleterm/host: protos/all
	$(BUF) generate --template=lib/prehog/buf-teleterm.gen.yaml lib/prehog/proto
	$(BUF) generate --template=lib/teleterm/buf.gen.yaml lib/teleterm/api/proto

.PHONY: goinstall
goinstall:
	go install $(BUILDFLAGS) \
		github.com/gravitational/teleport/tool/tsh \
		github.com/gravitational/teleport/tool/teleport \
		github.com/gravitational/teleport/tool/tctl

# make install will installs system-wide teleport
.PHONY: install
install: build
	@echo "\n** Make sure to run 'make install' as root! **\n"
	cp -f $(BUILDDIR)/tctl      $(BINDIR)/
	cp -f $(BUILDDIR)/tsh       $(BINDIR)/
	cp -f $(BUILDDIR)/teleport  $(BINDIR)/
	mkdir -p $(DATADIR)

# Docker image build. Always build the binaries themselves within docker (see
# the "docker" rule) to avoid dependencies on the host libc version.
.PHONY: image
image: OS=linux
image: TARBALL_PATH_SECTION:=-s "$(shell pwd)"
image: clean docker-binaries build-archive oss-deb
	cp ./build.assets/charts/Dockerfile $(BUILDDIR)/
	cd $(BUILDDIR) && docker build --no-cache . -t $(DOCKER_IMAGE):$(VERSION)-$(ARCH) --target teleport \
		--build-arg DEB_PATH="./teleport_$(VERSION)_$(ARCH).deb"
	if [ -f e/Makefile ]; then $(MAKE) -C e image PIV=$(PIV); fi

.PHONY: print-version
print-version:
	@echo $(VERSION)

.PHONY: chart-ent
chart-ent:
	$(MAKE) -C e chart

RUNTIME_SECTION ?=
TARBALL_PATH_SECTION ?=

ifneq ("$(RUNTIME)", "")
	RUNTIME_SECTION := -r $(RUNTIME)
endif
ifneq ("$(OSS_TARBALL_PATH)", "")
	TARBALL_PATH_SECTION := -s $(OSS_TARBALL_PATH)
endif

# build .pkg
.PHONY: pkg
pkg:
	mkdir -p $(BUILDDIR)/
	cp ./build.assets/build-package.sh ./build.assets/build-common.sh $(BUILDDIR)/
	chmod +x $(BUILDDIR)/build-package.sh
	# arch and runtime are currently ignored on OS X
	# we pass them through for consistency - they will be dropped by the build script
	cd $(BUILDDIR) && ./build-package.sh -t oss -v $(VERSION) -p pkg -a $(ARCH) $(RUNTIME_SECTION) $(TARBALL_PATH_SECTION)
	if [ -f e/Makefile ]; then $(MAKE) -C e pkg; fi

# build tsh client-only .pkg
.PHONY: pkg-tsh
pkg-tsh:
	./build.assets/build-pkg-tsh.sh -t oss -v $(VERSION) $(TARBALL_PATH_SECTION)
	mkdir -p $(BUILDDIR)/
	mv tsh*.pkg* $(BUILDDIR)/

# build .rpm
.PHONY: rpm
rpm:
	mkdir -p $(BUILDDIR)/
	cp ./build.assets/build-package.sh ./build.assets/build-common.sh $(BUILDDIR)/
	chmod +x $(BUILDDIR)/build-package.sh
	cp -a ./build.assets/rpm $(BUILDDIR)/
	cp -a ./build.assets/rpm-sign $(BUILDDIR)/
	cd $(BUILDDIR) && ./build-package.sh -t oss -v $(VERSION) -p rpm -a $(ARCH) $(RUNTIME_SECTION) $(TARBALL_PATH_SECTION)
	if [ -f e/Makefile ]; then $(MAKE) -C e rpm; fi

# build unsigned .rpm (for testing)
.PHONY: rpm-unsigned
rpm-unsigned:
	$(MAKE) UNSIGNED_RPM=true rpm

# build open source .deb only
.PHONY: oss-deb
oss-deb:
	mkdir -p $(BUILDDIR)/
	cp ./build.assets/build-package.sh ./build.assets/build-common.sh $(BUILDDIR)/
	chmod +x $(BUILDDIR)/build-package.sh
	cd $(BUILDDIR) && ./build-package.sh -t oss -v $(VERSION) -p deb -a $(ARCH) $(RUNTIME_SECTION) $(TARBALL_PATH_SECTION)

# build .deb
.PHONY: deb
deb: oss-deb
	if [ -f e/Makefile ]; then $(MAKE) -C e deb; fi

# check binary compatibility with different OSes
.PHONY: test-compat
test-compat:
	./build.assets/build-test-compat.sh

.PHONY: ensure-webassets
ensure-webassets:
	@if [ ! -d $(shell pwd)/webassets/teleport/ ]; then \
		$(MAKE) build-ui; \
	fi;

.PHONY: ensure-webassets-e
ensure-webassets-e:
	@if [ ! -d $(shell pwd)/webassets/e/teleport ]; then \
		$(MAKE) build-ui-e; \
	fi;

.PHONY: init-submodules-e
init-submodules-e:
	git submodule init e
	git submodule update

# dronegen generates .drone.yml config
#
#    Usage:
#    - tsh login --proxy=platform.teleport.sh
#    - tsh app login drone
#    - set $DRONE_TOKEN and $DRONE_SERVER (http://localhost:8080)
#    - tsh proxy app --port=8080 drone
#    - make dronegen
.PHONY: dronegen
dronegen:
	go run ./dronegen

# backport will automatically create backports for a given PR as long as you have the "gh" tool
# installed locally. To backport, type "make backport PR=1234 TO=branch/1,branch/2".
.PHONY: backport
backport:
	(cd ./assets/backport && go run main.go -pr=$(PR) -to=$(TO))

.PHONY: ensure-js-deps
ensure-js-deps:
	yarn install --ignore-scripts

.PHONY: build-ui
build-ui: ensure-js-deps
	yarn build-ui-oss

.PHONY: build-ui-e
build-ui-e: ensure-js-deps
	yarn build-ui-e

.PHONY: docker-ui
docker-ui:
	$(MAKE) -C build.assets ui
