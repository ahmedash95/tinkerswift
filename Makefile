SHELL := /bin/zsh

PROJECT := TinkerSwift.xcodeproj
SCHEME := TinkerSwift
CONFIGURATION := Debug
DERIVED_DATA := .build-xcode
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/TinkerSwift.app

.PHONY: help generate build run test

help:
	@echo "Available targets:"
	@echo "  make generate  - Regenerate Xcode project"
	@echo "  make build     - Build app (Debug)"
	@echo "  make run       - Build and launch app"
	@echo "  make test      - Run unit tests"

generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

run: build
	open $(APP_PATH)

test:
	xcodebuild -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -derivedDataPath $(DERIVED_DATA) \
	  test
