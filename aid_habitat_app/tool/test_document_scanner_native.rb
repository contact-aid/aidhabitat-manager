#!/usr/bin/env ruby
# Native UIKit regression tests without launching the Flutter application.
# Usage: ruby tool/test_document_scanner_native.rb SIMULATOR_UUID
require 'fileutils'
require 'pathname'
begin
  require 'xcodeproj'
rescue LoadError
  Gem.paths = { 'GEM_HOME' => ENV.fetch('COCOAPODS_GEM_HOME', '/opt/homebrew/opt/cocoapods/libexec') }
  require 'xcodeproj'
end

abort 'Pass an iPad simulator UUID' unless ARGV.length == 1
app_dir = File.expand_path('..', __dir__)
build_dir = File.join(app_dir, 'build', 'scanner-harness')
FileUtils.mkdir_p(build_dir)
flutter = Pathname.new(`which flutter`.strip).realpath.dirname.parent
framework = flutter.join('bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework').to_s
abort "Flutter simulator framework missing: #{framework}" unless File.directory?(framework)

File.write(File.join(build_dir, 'Harness.swift'), <<~SWIFT)
  import UIKit
  @main final class HarnessDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
      DocumentScannerPlugin.scannerOrientationMask ?? .all
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
      options: UIScene.ConnectionOptions) -> UISceneConfiguration {
      let config = UISceneConfiguration(name: "Scanner tests", sessionRole: session.role)
      config.delegateClass = HarnessSceneDelegate.self
      return config
    }
  }
  final class HarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
      guard let scene = scene as? UIWindowScene else { return }
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIViewController()
      window.makeKeyAndVisible()
      self.window = window
    }
  }
SWIFT

project_path = File.join(build_dir, 'ScannerHarness.xcodeproj')
# Recreate only the generated project; leave build products for incremental tests.
FileUtils.rm_r(project_path) if File.directory?(project_path)
project = Xcodeproj::Project.new(project_path)
app = project.new_target(:application, 'Runner', :ios, '26.5')
tests = project.new_target(:unit_test_bundle, 'RunnerTests', :ios, '26.5')
tests.add_dependency(app)
app.add_file_references([
  project.main_group.new_file(File.join(build_dir, 'Harness.swift')),
  project.main_group.new_file(File.join(app_dir, 'ios/Runner/DocumentScannerPlugin.swift'))
])
tests.add_file_references([project.main_group.new_file(File.join(app_dir, 'ios/RunnerTests/RunnerTests.swift'))])
flutter_ref = project.frameworks_group.new_file(framework)
[app, tests].each do |target|
  target.frameworks_build_phase.add_file_reference(flutter_ref)
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0', 'PRODUCT_BUNDLE_IDENTIFIER' => "com.aidhabitat.scanner-regression.#{target.name}",
      'GENERATE_INFOPLIST_FILE' => 'YES', 'CODE_SIGNING_ALLOWED' => 'NO', 'TARGETED_DEVICE_FAMILY' => '2',
      'FRAMEWORK_SEARCH_PATHS' => ['$(inherited)', File.dirname(framework)],
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
      'ENABLE_TESTABILITY' => 'YES'
    })
  end
end
app.build_configurations.each do |config|
  config.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UIRequiresFullScreen'] = 'YES'
end
embed = app.new_copy_files_build_phase('Embed Flutter')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(flutter_ref).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
tests.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Runner.app/Runner'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'Runner', true)
exec 'xcodebuild', '-project', project_path, '-scheme', 'Runner', '-destination',
  "platform=iOS Simulator,id=#{ARGV.first}", '-derivedDataPath', File.join(build_dir, 'DerivedData'),
  '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', 'test'
