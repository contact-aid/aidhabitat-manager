#!/usr/bin/env ruby
require 'fileutils'
require 'pathname'
begin
  require 'xcodeproj'
rescue LoadError
  Gem.paths = { 'GEM_HOME' => ENV.fetch('COCOAPODS_GEM_HOME', '/opt/homebrew/opt/cocoapods/libexec') }
  require 'xcodeproj'
end
abort 'Usage: ruby tool/scanner_device_test/build.rb DEVICE_UDID' unless ARGV.length == 1
app_dir = File.expand_path('../..', __dir__)
build_dir = File.join(app_dir, 'build/scanner-device-test')
FileUtils.mkdir_p(build_dir)
flutter = Pathname.new(`which flutter`.strip).realpath.dirname.parent
framework = flutter.join('bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64/Flutter.framework').to_s
project_path = File.join(build_dir, 'ScanTest.xcodeproj')
FileUtils.rm_r(project_path) if File.directory?(project_path)
project = Xcodeproj::Project.new(project_path)
app = project.new_target(:application, 'ScanTest', :ios, '26.5')
app.add_file_references([
  project.main_group.new_file(File.join(__dir__, 'ScannerTestApp.swift')),
  project.main_group.new_file(File.join(app_dir, 'ios/Runner/DocumentScannerPlugin.swift'))
])
ref = project.frameworks_group.new_file(framework)
app.frameworks_build_phase.add_file_reference(ref)
embed = app.new_copy_files_build_phase('Embed Flutter')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(ref).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
app.build_configurations.each do |config|
  config.build_settings.merge!({
    'SWIFT_VERSION' => '5.0', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.aidhabitat.scannertest',
    'DEVELOPMENT_TEAM' => 'HRFWLL68V9', 'CODE_SIGN_STYLE' => 'Automatic',
    'GENERATE_INFOPLIST_FILE' => 'YES', 'TARGETED_DEVICE_FAMILY' => '2',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Scan Test',
    'INFOPLIST_KEY_CFBundleDevelopmentRegion' => 'fr',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'INFOPLIST_KEY_UIRequiresFullScreen' => 'YES',
    'INFOPLIST_KEY_NSCameraUsageDescription' => 'Tester le scan de documents et la prise de photo sur cet iPad.',
    'FRAMEWORK_SEARCH_PATHS' => ['$(inherited)', File.dirname(framework)],
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0'
  })
end
project.root_object.attributes['DevelopmentTeam'] = 'HRFWLL68V9'
project.root_object.development_region = 'fr'
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'ScanTest', true)
exec 'xcodebuild', '-project', project_path, '-scheme', 'ScanTest', '-configuration', 'Release',
  '-destination', "platform=iOS,id=#{ARGV.first}", '-derivedDataPath', File.join(build_dir, 'DerivedData'),
  '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build'
