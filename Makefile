# Makefile - Cross-platform build and packaging automation for MacHost iPadOS container (.ipa)

# Target configuration
TARGET_ARCH ?= arm64
MIN_IOS_VER ?= 14.0
APP_NAME    ?= HostApp
BUNDLE_ID   ?= com.antigravity.machost
IPA_NAME    ?= MacHost.ipa

# Directory paths
BUILD_DIR   ?= build
PAYLOAD_DIR := $(BUILD_DIR)/Payload
APP_DIR     := $(PAYLOAD_DIR)/$(APP_NAME).app
FRAMEWORKS_DIR := $(APP_DIR)/Frameworks

# Toolchain detection
CC          ?= xcrun -sdk iphoneos clang
HOST_CC     ?= clang
LDID        ?= $(shell which ldid 2>/dev/null || echo true)
CODESIGN    ?= $(shell which codesign 2>/dev/null || echo true)
ZIP         ?= zip

# SDK resolution
ifeq ($(shell uname -s 2>/dev/null),Darwin)
    SDK_PATH := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
    IOS_TARGET := -target $(TARGET_ARCH)-apple-ios$(MIN_IOS_VER) -isysroot $(SDK_PATH)
else
    IOS_TARGET := -target $(TARGET_ARCH)-apple-ios$(MIN_IOS_VER)
endif

CFLAGS      := -O2 -Wall -Wextra -fobjc-arc $(IOS_TARGET)
INCLUDES    := -I MachOPatcher -I DyldInterpose -I AppKitShim -I HostHarness
LDFLAGS     := -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Metal

.PHONY: all clean ipa test host-tools dirs

all: ipa

dirs:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(PAYLOAD_DIR)
	mkdir -p $(APP_DIR)
	mkdir -p $(FRAMEWORKS_DIR)

# 1. MachOPatcher CLI for host
host-tools: dirs
	$(HOST_CC) -O2 -Wall -Wextra -I MachOPatcher MachOPatcher/MachOPatcher.c MachOPatcher/machopatch_cli.c -o $(BUILD_DIR)/machopatch

# 2. DyldInterpose dynamic library
$(FRAMEWORKS_DIR)/libDyldInterpose.dylib: dirs DyldInterpose/DyldInterpose.c DyldInterpose/DyldInterpose.h
	$(CC) $(CFLAGS) -dynamiclib -install_name @rpath/libDyldInterpose.dylib \
		DyldInterpose/DyldInterpose.c -o $@

# 3. AppKitShim framework
$(FRAMEWORKS_DIR)/AppKitShim.framework/AppKitShim: dirs AppKitShim/AppKitShim.m AppKitShim/MetalPresenter.m
	mkdir -p $(FRAMEWORKS_DIR)/AppKitShim.framework/Headers
	$(CC) $(CFLAGS) $(INCLUDES) -dynamiclib \
		-install_name @rpath/AppKitShim.framework/AppKitShim \
		-framework Foundation -framework CoreGraphics -framework QuartzCore -framework Metal -framework UIKit \
		AppKitShim/AppKitShim.m AppKitShim/MetalPresenter.m -o $@
	cp AppKitShim/AppKitShim.h AppKitShim/MetalPresenter.h $(FRAMEWORKS_DIR)/AppKitShim.framework/Headers/
	cp AppKitShim/Info.plist $(FRAMEWORKS_DIR)/AppKitShim.framework/Info.plist

# 4. HostApp Main Executable
$(APP_DIR)/$(APP_NAME): dirs $(FRAMEWORKS_DIR)/libDyldInterpose.dylib $(FRAMEWORKS_DIR)/AppKitShim.framework/AppKitShim
	$(CC) $(CFLAGS) $(INCLUDES) \
		MachOPatcher/MachOPatcher.c \
		HostHarness/JITHelper.m \
		HostHarness/ContainerViewController.m \
		HostHarness/AppDelegate.m \
		HostHarness/main.m \
		-L$(FRAMEWORKS_DIR) -lDyldInterpose \
		-F$(FRAMEWORKS_DIR) -framework AppKitShim \
		-Xlinker -rpath -Xlinker @executable_path/Frameworks \
		$(LDFLAGS) -o $@

# 5. Assemble Bundle & Sign
bundle: $(APP_DIR)/$(APP_NAME)
	cp HostHarness/Info.plist $(APP_DIR)/Info.plist
	@if [ -x "$$(which ldid 2>/dev/null)" ]; then \
		echo "Signing with ldid..."; \
		ldid -S $(FRAMEWORKS_DIR)/libDyldInterpose.dylib; \
		ldid -S $(FRAMEWORKS_DIR)/AppKitShim.framework/AppKitShim; \
		ldid -SHostHarness/Entitlements.plist $(APP_DIR)/$(APP_NAME); \
	elif [ -x "$$(which codesign 2>/dev/null)" ]; then \
		echo "Signing with codesign ad-hoc..."; \
		codesign -s - --force $(FRAMEWORKS_DIR)/libDyldInterpose.dylib; \
		codesign -s - --force $(FRAMEWORKS_DIR)/AppKitShim.framework; \
		codesign -s - --entitlements HostHarness/Entitlements.plist --force $(APP_DIR)/$(APP_NAME); \
	fi

# 6. Package into .ipa
ipa: bundle
	cd $(BUILD_DIR) && $(ZIP) -qry $(IPA_NAME) Payload
	@echo "Built signed package: $(BUILD_DIR)/$(IPA_NAME)"

# Unit tests
test:
	$(HOST_CC) -O2 -Wall -Wextra -I MachOPatcher MachOPatcher/MachOPatcher.c tests/test_machopatcher.c -o $(BUILD_DIR)/test_machopatcher
	$(BUILD_DIR)/test_machopatcher

clean:
	rm -rf $(BUILD_DIR)
