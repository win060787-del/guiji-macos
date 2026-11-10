#!/usr/bin/env ruby
# Developer-only generator. The checked-in project builds without Ruby dependencies.
require 'xcodeproj'
Dir.chdir(File.expand_path('..', __dir__))
path = 'NovaContext.xcodeproj'
def apply_app_names(project, target)
  target.build_configurations.each { |config| config.build_settings['PRODUCT_NAME'] = 'Guiji' }
  project.root_object.development_region = 'en'
  resources = project.main_group['Resources']
  return if resources['InfoPlist.strings']
  names = resources.new_variant_group('InfoPlist.strings')
  %w[zh-Hans zh-Hant].each do |language|
    file = names.new_file("Packaging/#{language}.lproj/InfoPlist.strings")
    file.name = language
  end
  target.resources_build_phase.add_file_reference(names)
end

if ARGV == ['--update-names']
  project = Xcodeproj::Project.open(path)
  apply_app_names(project, project.targets.find { |target| target.name == 'NovaContext' })
  project.save
  exit
end

abort 'Project exists; edit it instead of overwriting.' if File.exist?(path)
p = Xcodeproj::Project.new(path)
t = p.new_target(:application, 'NovaContext', :osx, '14.0')
t.build_configurations.each do |c|
  c.build_settings.merge!({
    'PRODUCT_NAME'=>'Guiji', 'PRODUCT_MODULE_NAME'=>'NovaContext',
    'PRODUCT_BUNDLE_IDENTIFIER'=>'com.novatechai.context', 'DEVELOPMENT_TEAM'=>'7DXNZ5SH9Z',
    'CODE_SIGN_STYLE'=>'Automatic', 'CODE_SIGN_ENTITLEMENTS'=>'Packaging/AppStore.entitlements',
    'ENABLE_APP_SANDBOX'=>'YES', 'ENABLE_HARDENED_RUNTIME'=>'YES',
    'ENABLE_USER_SELECTED_FILES'=>'readwrite', 'ARCHS'=>'arm64', 'ONLY_ACTIVE_ARCH'=>'NO',
    'SWIFT_VERSION'=>'5.0', 'MACOSX_DEPLOYMENT_TARGET'=>'14.0',
    'INFOPLIST_FILE'=>'Packaging/Info.plist', 'GENERATE_INFOPLIST_FILE'=>'NO',
    'MARKETING_VERSION'=>'1.0.0', 'CURRENT_PROJECT_VERSION'=>'22',
    'ASSETCATALOG_COMPILER_APPICON_NAME'=>'AppIcon', 'COMBINE_HIDPI_IMAGES'=>'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING'=>'YES', 'SWIFT_EMIT_LOC_STRINGS'=>'NO',
    'LD_RUNPATH_SEARCH_PATHS'=>'$(inherited) @executable_path/../Frameworks'
  })
end
sources = p.main_group.new_group('Application')
Dir.glob('Sources/NovaContext/*.swift').sort.each { |f| t.source_build_phase.add_file_reference(sources.new_file(f)) }
resources = p.main_group.new_group('Resources')
%w[Sources/NovaContext/Resources Sources/NovaContext/BrandAssets.xcassets Packaging/AppAssets.xcassets Packaging/PrivacyInfo.xcprivacy Packaging/Licenses scripts/nova-agent.py].each do |f|
  r = resources.new_file(f); r.last_known_file_type = 'folder' if File.directory?(f) && !f.end_with?('.xcassets')
  t.resources_build_phase.add_file_reference(r)
end
package = p.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
p.root_object.package_references << package
product = p.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package; product.product_name = 'ContextCore'
t.package_product_dependencies << product
bf = p.new(Xcodeproj::Project::Object::PBXBuildFile); bf.product_ref = product; t.frameworks_build_phase.files << bf
p.root_object.development_region = 'en'; p.root_object.known_regions = ['en','zh-Hans','zh-Hant','es','tr','ja','Base']
p.root_object.attributes['TargetAttributes'] = { t.uuid => { 'SystemCapabilities'=>{'com.apple.Sandbox'=>{'enabled'=>1},'com.apple.HardenedRuntime'=>{'enabled'=>1}} } }
apply_app_names(p, t)
p.save
scheme = Xcodeproj::XCScheme.new; scheme.add_build_target(t); scheme.set_launch_target(t)
scheme.archive_action.build_configuration = 'Release'; scheme.save_as(p.path,'NovaContext',true)
puts path
