#!/usr/bin/env python3
"""Generate the dependency-free Xcode project. Stable IDs keep diffs readable."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
objects = []
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def obj(key, text):
    uid = ident(key); objects.append(f'{uid} = {{ {text} }};'); return uid
def quote(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
sources = sorted((root/'Sources/BasedFTP').glob('*.swift'))
refs=[]; builds=[]
for source in sources:
    rel=str(source.relative_to(root))
    ref=obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(rel)}; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    builds.append(obj('build'+rel, f'isa = PBXBuildFile; fileRef = {ref};'))
iconRef=obj('iconref', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = SOURCE_ROOT;')
iconBuild=obj('iconbuild', f'isa = PBXBuildFile; fileRef = {iconRef};')
refs.append(iconRef)
licenseRef=obj('licenseref', 'isa = PBXFileReference; lastKnownFileType = text; path = LICENSE; sourceTree = SOURCE_ROOT;')
licenseBuild=obj('licensebuild', f'isa = PBXBuildFile; fileRef = {licenseRef};')
refs.append(licenseRef)
testRefs=[]; testBuilds=[]
for source in sorted((root/'Tests/BasedFTPTests').glob('*.swift')):
    rel=str(source.relative_to(root))
    ref=obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(rel)}; sourceTree = SOURCE_ROOT;')
    testRefs.append(ref)
    testBuilds.append(obj('build'+rel, f'isa = PBXBuildFile; fileRef = {ref};'))
testProduct=obj('testproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = BasedFTPTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
testGroup=obj('testgroup', f'isa = PBXGroup; children = ({",".join(testRefs)},); name = Tests; sourceTree = "<group>";')
product=obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = BasedFTP.app; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products', f'isa = PBXGroup; children = ({product},{testProduct},); name = Products; sourceTree = "<group>";')
group=obj('group', f'isa = PBXGroup; children = ({",".join(refs)},{testGroup},{products},); sourceTree = "<group>";')
sourcesPhase=obj('sourcesphase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconBuild},{licenseBuild},); runOnlyForDeploymentPostprocessing = 0;')
configs=[]; projectConfigs=[]
for mode in ['Debug','Release']:
    settings='ARCHS = "arm64 x86_64"; ONLY_ACTIVE_ARCH = NO; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "-"; COMBINE_HIDPI_IMAGES = YES; ENABLE_APP_SANDBOX = NO; ENABLE_HARDENED_RUNTIME = YES; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools"; INFOPLIST_KEY_CFBundleDisplayName = BasedFTP; INFOPLIST_KEY_CFBundleDevelopmentRegion = en; INFOPLIST_KEY_CFBundleIconFile = AppIcon; MACOSX_DEPLOYMENT_TARGET = 14.0; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; PRODUCT_BUNDLE_IDENTIFIER = app.basedftp.client; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; SWIFT_EMIT_LOC_STRINGS = YES;'
    if mode=='Debug': settings+=' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; ENABLE_TESTABILITY = YES;'
    else: settings+=' SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O";'
    configs.append(obj('target'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {mode};'))
    projectConfigs.append(obj('project'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; }}; name = {mode};'))
configList=obj('configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
projectConfigList=obj('projectconfiglist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(projectConfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {configList}; buildPhases = ({sourcesPhase},{frameworks},{resources},); buildRules = (); dependencies = (); name = BasedFTP; productName = BasedFTP; productReference = {product}; productType = "com.apple.product-type.application";')
testPhase=obj('testphase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(testBuilds)},); runOnlyForDeploymentPostprocessing = 0;')
testFrameworks=obj('testframeworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
testConfigs=[]
for mode in ['Debug','Release']:
    testConfigs.append(obj('test'+mode, f'isa = XCBuildConfiguration; buildSettings = {{ GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = app.basedftp.tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 14.0; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "-"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BasedFTP.app/Contents/MacOS/BasedFTP"; BUNDLE_LOADER = "$(TEST_HOST)"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks"; }}; name = {mode};'))
testConfigList=obj('testconfiglist', f'isa = XCConfigurationList; buildConfigurations = ({",".join(testConfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
proxy=obj('testproxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = BasedFTP;')
dependency=obj('testdependency', f'isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};')
testTarget=obj('testtarget', f'isa = PBXNativeTarget; buildConfigurationList = {testConfigList}; buildPhases = ({testPhase},{testFrameworks},); buildRules = (); dependencies = ({dependency},); name = BasedFTPTests; productName = BasedFTPTests; productReference = {testProduct}; productType = "com.apple.product-type.bundle.unit-test";')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {projectConfigList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{testTarget},);')
(root/'BasedFTP.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
(root/'BasedFTP.xcodeproj/xcshareddata/xcschemes/BasedFTP.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="BasedFTP.app" BlueprintName="BasedFTP" ReferencedContainer="container:BasedFTP.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testTarget}" BuildableName="BasedFTPTests.xctest" BlueprintName="BasedFTPTests" ReferencedContainer="container:BasedFTP.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="BasedFTP.app" BlueprintName="BasedFTP" ReferencedContainer="container:BasedFTP.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
