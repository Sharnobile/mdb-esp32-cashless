#!/usr/bin/env ruby
# frozen_string_literal: true

# Creates the VMflowScreenshots UI-test target via the `xcodeproj` gem rather
# than hand-editing pbxproj hex IDs — a whole target is ~10 interlocking
# pbxproj sections (PBXNativeTarget, PBXBuildFile, PBXFileReference,
# PBXGroup, PBXSourcesBuildPhase, PBXFrameworksBuildPhase,
# PBXResourcesBuildPhase, PBXContainerItemProxy, PBXTargetDependency,
# XCConfigurationList/XCBuildConfiguration) and hand-crafting those is where
# silent corruption lives. Run once: `bundle exec ruby scripts/add_screenshots_target.rb`
# from the `ios/` directory. Idempotent-guarded — aborts if the target already
# exists so re-running never duplicates sections.

require "xcodeproj"

PROJECT_PATH = File.join(__dir__, "..", "VMflow.xcodeproj")
SCHEME_PATH = File.join(PROJECT_PATH, "xcshareddata", "xcschemes", "VMflow.xcscheme")
TARGET_NAME = "VMflowScreenshots"
APP_TARGET_NAME = "VMflow"
APP_TARGET_ID = "896CD9A61911762E88A22E98"

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == TARGET_NAME }
  abort "#{TARGET_NAME} target already exists — aborting (script is idempotent-guarded, delete the target first if you really want to recreate it)."
end

app_target = project.targets.find { |t| t.uuid == APP_TARGET_ID }
abort "Could not find app target with UUID #{APP_TARGET_ID}" unless app_target
abort "App target UUID #{APP_TARGET_ID} is not named #{APP_TARGET_NAME} (found #{app_target.name}) — check the plan's hardcoded ID is still correct" unless app_target.name == APP_TARGET_NAME

# --- Group -------------------------------------------------------------
# A dedicated group pointing at the VMflowScreenshots/ directory, sibling to
# the VMflow app group, so the two Swift files show up nested in Xcode's
# navigator instead of floating at the project root.
screenshots_group = project.main_group.new_group(TARGET_NAME, TARGET_NAME)

# --- Target --------------------------------------------------------------
target = project.new_target(:ui_test_bundle, TARGET_NAME, :ios, "17.0")

# --- Sources ---------------------------------------------------------------
%w[SnapshotHelper.swift VMflowScreenshotsTests.swift].each do |filename|
  file_ref = screenshots_group.new_reference(filename)
  target.add_file_references([file_ref])
end

# --- Build settings (both configurations) -----------------------------
target.build_configurations.each do |config|
  config.build_settings["TEST_TARGET_NAME"] = APP_TARGET_NAME
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "de.kerl-handel.app.screenshots"
  config.build_settings["DEVELOPMENT_TEAM"] = "4JT3V7XVXM"
  # The new target inherits GENERATE_INFOPLIST_FILE=NO + an app-specific
  # INFOPLIST_FILE from the project-level configs unless overridden here —
  # both MUST be set on the target itself.
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["INFOPLIST_FILE"] = ""
  config.build_settings["SWIFT_VERSION"] = "5.9"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
end

# --- Test target dependency ------------------------------------------------
target.add_dependency(app_target)

# --- TargetAttributes: TestTargetID -----------------------------------
attributes = project.root_object.attributes["TargetAttributes"] ||= {}
attributes[target.uuid] = { "TestTargetID" => APP_TARGET_ID }

project.save
puts "Added #{TARGET_NAME} target (#{target.uuid}) to #{PROJECT_PATH}"

# --- Shared scheme: register the testable ---------------------------------
# TestableReference.new(target) builds the BuildableReference internally from
# the live PBXNativeTarget object (uuid/name/product name/container all
# derived from it) — passing raw fields to BuildableReference.new directly
# isn't its constructor signature (it wraps an XML node or takes a target).
scheme = Xcodeproj::XCScheme.new(SCHEME_PATH)
testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(target)
scheme.test_action.add_testable(testable)
scheme.save_as(PROJECT_PATH, "VMflow", true)
puts "Added #{TARGET_NAME} as a testable to the VMflow scheme's TestAction."
