#!/usr/bin/env python3
"""Writes CarAgent.xcodeproj from the folders (no third-party generator needed).

    python3 tools/make_project.py            # run from example_car_agent/ after adding or removing files

Targets:
  CarAgent       the app: every .swift / .m under CarAgent/, CarAgent/Resources as bundle resources (folders kept as folders),
                 the DaVoice xcframeworks from ../libs, ONNX Runtime from the DaVoiceOnnxRuntime Swift package.
  CarAgentTests  unit tests (hosted in the app): every .swift under CarAgentTests/, CarAgentTests/fixtures as a folder.

ONNX_RUNTIME below picks where the Swift package comes from: the published GitHub package (default) or a local checkout.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # example_car_agent/
PROJECT = os.path.join(ROOT, "CarAgent.xcodeproj")

# ONNX Runtime 1.31.0 (the same build as the DaVoiceOnnxRuntime pod). "remote" = the GitHub Swift package; "local" = a checkout
# next to this repository (useful before a release).
ONNX_RUNTIME = os.environ.get("DV_ORT", "remote")
ORT_URL = "https://github.com/frymanofer/DaVoiceOnnxRuntime"
ORT_VERSION = "1.31.0"
ORT_LOCAL = "../../DaVoiceOnnxRuntime"

FRAMEWORKS = ["KeyWordDetection.xcframework", "DavoiceTTS.xcframework", "DavoiceLLM.xcframework"]
SYSTEM_FRAMEWORKS = ["AVFoundation", "Accelerate", "CoreML", "Metal", "MetalKit", "Speech"]
BUNDLE_ID = "io.davoice.caragent.ios"
DEPLOYMENT = "15.1"


def oid(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def q(s):
    """A pbxproj string: bare when safe, else quoted."""
    if s and all(c.isalnum() or c in "._/$" for c in s) and not s[0].isdigit():
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


FILE_TYPES = {
    ".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h", ".json": "text.json",
    ".txt": "text", ".dm": "file", ".plist": "text.plist.xml", ".ttf": "file", ".xcframework": "wrapper.xcframework",
    ".xcassets": "folder.assetcatalog", ".md": "net.daringfireball.markdown", ".entitlements": "text.plist.entitlements",
}


class Proj:
    def __init__(self):
        self.objects = {}  # id -> (isa, dict)

    def add(self, key, isa, **fields):
        i = oid(isa, key)
        self.objects[i] = (isa, fields)
        return i

    def render(self, root):
        by_isa = {}
        for i, (isa, f) in self.objects.items():
            by_isa.setdefault(isa, []).append((i, f))
        out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {"]
        for isa in sorted(by_isa):
            out.append(f"\n/* Begin {isa} section */")
            for i, f in sorted(by_isa[isa]):
                out.append(f"\t\t{i} = {self.value(dict(isa=isa, **f), 2)};")
            out.append(f"/* End {isa} section */")
        out += ["\t};", f"\trootObject = {root};", "}", ""]
        return "\n".join(out)

    def value(self, v, depth):
        tabs = "\t" * (depth + 1)
        if isinstance(v, dict):
            items = [f"{tabs}{q(k)} = {self.value(x, depth + 1)};" for k, x in v.items()]
            return "{\n" + "\n".join(items) + "\n" + "\t" * depth + "}"
        if isinstance(v, list):
            items = [f"{tabs}{self.value(x, depth + 1)}," for x in v]
            return "(\n" + "\n".join(items) + "\n" + "\t" * depth + ")"
        return q(str(v))


def walk_group(p, folder, rel, kinds, folder_refs=()):
    """A group for CarAgent/<rel>; returns (group id, [(file id, path)] per kind). Folders in folder_refs become folder references."""
    children, found = [], {k: [] for k in kinds}
    full = os.path.join(ROOT, folder, rel)
    for name in sorted(os.listdir(full)):
        if name.startswith(".") or name == "README.md":
            continue
        path = os.path.join(rel, name) if rel else name
        abs_path = os.path.join(full, name)
        ext = os.path.splitext(name)[1]
        if os.path.isdir(abs_path) and ext not in (".xcassets",) and path not in folder_refs:
            g, sub = walk_group(p, folder, path, kinds, folder_refs)
            children.append(g)
            for k in kinds:
                found[k] += sub[k]
            continue
        ftype = "folder" if os.path.isdir(abs_path) and ext != ".xcassets" else FILE_TYPES.get(ext, "file")
        fid = p.add(f"{folder}/{path}", "PBXFileReference", lastKnownFileType=ftype, path=name, sourceTree="<group>")
        children.append(fid)
        if ext in (".swift", ".m"):
            found["sources"].append((fid, path))
        elif ext in (".h", ".plist", ".entitlements"):
            pass
        elif "resources" in kinds:
            found["resources"].append((fid, path))
    name = os.path.basename(rel) if rel else folder
    g = p.add(f"group:{folder}/{rel}", "PBXGroup", children=children, path=name, sourceTree="<group>")
    return g, found


def main():
    p = Proj()
    app_group, app = walk_group(p, "CarAgent", "", ["sources", "resources"], folder_refs=(
        "Resources/agent_automotive", "Resources/car", "Resources/fonts"))
    test_group, tests = walk_group(p, "CarAgentTests", "", ["sources", "resources"], folder_refs=("fixtures",))

    fw_refs = [p.add(f"libs/{f}", "PBXFileReference", lastKnownFileType="wrapper.xcframework", path=f, sourceTree="<group>")
               for f in FRAMEWORKS]
    sys_refs = [p.add(f"sys/{f}", "PBXFileReference", lastKnownFileType="wrapper.framework", name=f"{f}.framework",
                      path=f"System/Library/Frameworks/{f}.framework", sourceTree="SDKROOT") for f in SYSTEM_FRAMEWORKS]
    libs_group = p.add("group:libs", "PBXGroup", children=fw_refs, name="DaVoice frameworks", path="../libs", sourceTree="<group>")
    sys_group = p.add("group:sys", "PBXGroup", children=sys_refs, name="System frameworks", sourceTree="<group>")
    app_product = p.add("product:app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0",
                        path="CarAgent.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = p.add("product:tests", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0",
                         path="CarAgentTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = p.add("group:products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
    main_group = p.add("group:main", "PBXGroup", children=[app_group, test_group, libs_group, sys_group, products], sourceTree="<group>")

    # ONNX Runtime package
    if ONNX_RUNTIME == "local":
        pkg = p.add("pkg:ort", "XCLocalSwiftPackageReference", relativePath=ORT_LOCAL)
    else:
        pkg = p.add("pkg:ort", "XCRemoteSwiftPackageReference", repositoryURL=ORT_URL,
                    requirement={"kind": "upToNextMinorVersion", "minimumVersion": ORT_VERSION})
    ort_product = p.add("pkgprod:ort", "XCSwiftPackageProductDependency", package=pkg, productName="DaVoiceOnnxRuntime")

    def build_files(target, items):
        return [p.add(f"bf:{target}:{fid}", "PBXBuildFile", fileRef=fid) for fid, _ in items]

    app_sources = p.add("phase:app:sources", "PBXSourcesBuildPhase", buildActionMask="2147483647",
                        files=build_files("app", app["sources"]), runOnlyForDeploymentPostprocessing="0")
    app_resources = p.add("phase:app:resources", "PBXResourcesBuildPhase", buildActionMask="2147483647",
                          files=build_files("app", app["resources"]), runOnlyForDeploymentPostprocessing="0")
    fw_files = [p.add(f"bf:app:fw:{f}", "PBXBuildFile", fileRef=r) for f, r in zip(FRAMEWORKS, fw_refs)]
    fw_files += [p.add(f"bf:app:sys:{f}", "PBXBuildFile", fileRef=r) for f, r in zip(SYSTEM_FRAMEWORKS, sys_refs)]
    fw_files.append(p.add("bf:app:ort", "PBXBuildFile", productRef=ort_product))
    app_frameworks = p.add("phase:app:frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647",
                           files=fw_files, runOnlyForDeploymentPostprocessing="0")

    test_sources = p.add("phase:test:sources", "PBXSourcesBuildPhase", buildActionMask="2147483647",
                         files=build_files("test", tests["sources"]), runOnlyForDeploymentPostprocessing="0")
    test_resources = p.add("phase:test:resources", "PBXResourcesBuildPhase", buildActionMask="2147483647",
                           files=build_files("test", tests["resources"]), runOnlyForDeploymentPostprocessing="0")
    test_frameworks = p.add("phase:test:frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647",
                            files=[], runOnlyForDeploymentPostprocessing="0")

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT, "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    proj_configs = []
    for name, extra in (("Debug", {"DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES",
                                   "GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                   "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"]}),
                        ("Release", {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-O",
                                     "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})):
        proj_configs.append(p.add(f"cfg:proj:{name}", "XCBuildConfiguration", buildSettings={**common, **extra}, name=name))
    proj_list = p.add("cfglist:proj", "XCConfigurationList", buildConfigurations=proj_configs, defaultConfigurationIsVisible="0",
                      defaultConfigurationName="Release")

    app_settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "INFOPLIST_FILE": "CarAgent/App/Info.plist",
        "SWIFT_OBJC_BRIDGING_HEADER": "CarAgent/Bridges/CarAgent-Bridging-Header.h", "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0",
        "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(PROJECT_DIR)/../libs"],
        "OTHER_LDFLAGS": ["$(inherited)", "-ObjC", "-lc++", "-lz", "-lsqlite3"],
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "ENABLE_BITCODE": "NO", "CLANG_ENABLE_MODULES": "YES", "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    }
    app_configs = [p.add(f"cfg:app:{n}", "XCBuildConfiguration", buildSettings=dict(app_settings), name=n) for n in ("Debug", "Release")]
    app_list = p.add("cfglist:app", "XCConfigurationList", buildConfigurations=app_configs, defaultConfigurationIsVisible="0",
                     defaultConfigurationName="Release")
    test_settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests", "GENERATE_INFOPLIST_FILE": "YES",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/CarAgent.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CarAgent",
        "BUNDLE_LOADER": "$(TEST_HOST)", "CODE_SIGN_STYLE": "Automatic",
        "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(PROJECT_DIR)/../libs"],
        "SWIFT_OBJC_BRIDGING_HEADER": "CarAgent/Bridges/CarAgent-Bridging-Header.h",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    }
    test_configs = [p.add(f"cfg:test:{n}", "XCBuildConfiguration", buildSettings=dict(test_settings), name=n) for n in ("Debug", "Release")]
    test_list = p.add("cfglist:test", "XCConfigurationList", buildConfigurations=test_configs, defaultConfigurationIsVisible="0",
                      defaultConfigurationName="Release")

    app_target = p.add("target:app", "PBXNativeTarget", buildConfigurationList=app_list,
                       buildPhases=[app_sources, app_frameworks, app_resources], buildRules=[], dependencies=[], name="CarAgent",
                       packageProductDependencies=[ort_product], productName="CarAgent", productReference=app_product,
                       productType="com.apple.product-type.application")
    proxy = p.add("proxy:tests", "PBXContainerItemProxy", containerPortal=oid("PBXProject", "project"), proxyType="1",
                  remoteGlobalIDString=app_target, remoteInfo="CarAgent")
    dep = p.add("dep:tests", "PBXTargetDependency", target=app_target, targetProxy=proxy)
    test_target = p.add("target:tests", "PBXNativeTarget", buildConfigurationList=test_list,
                        buildPhases=[test_sources, test_frameworks, test_resources], buildRules=[], dependencies=[dep],
                        name="CarAgentTests", productName="CarAgentTests", productReference=test_product,
                        productType="com.apple.product-type.bundle.unit-test")
    project = p.add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "1", "LastSwiftUpdateCheck": "2600",
                                                          "LastUpgradeCheck": "2600",
                                                          "TargetAttributes": {test_target: {"TestTargetID": app_target}}},
                    buildConfigurationList=proj_list, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0",
                    knownRegions=["en", "Base"], mainGroup=main_group, packageReferences=[pkg], productRefGroup=products,
                    projectDirPath="", projectRoot="", targets=[app_target, test_target])

    os.makedirs(os.path.join(PROJECT, "xcshareddata", "xcschemes"), exist_ok=True)
    with open(os.path.join(PROJECT, "project.pbxproj"), "w") as f:
        f.write(p.render(project))
    with open(os.path.join(PROJECT, "xcshareddata", "xcschemes", "CarAgent.xcscheme"), "w") as f:
        f.write(SCHEME.replace("@APP@", app_target).replace("@TEST@", test_target))
    print(f"wrote {PROJECT}: {len(app['sources'])} app sources, {len(app['resources'])} resources, {len(tests['sources'])} test sources,"
          f" ONNX Runtime: {ONNX_RUNTIME}")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "@APP@" BuildableName = "CarAgent.app" BlueprintName = "CarAgent" ReferencedContainer = "container:CarAgent.xcodeproj"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "@TEST@" BuildableName = "CarAgentTests.xctest" BlueprintName = "CarAgentTests" ReferencedContainer = "container:CarAgent.xcodeproj"></BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "@APP@" BuildableName = "CarAgent.app" BlueprintName = "CarAgent" ReferencedContainer = "container:CarAgent.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "@APP@" BuildableName = "CarAgent.app" BlueprintName = "CarAgent" ReferencedContainer = "container:CarAgent.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""

if __name__ == "__main__":
    sys.exit(main())
